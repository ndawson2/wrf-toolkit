#!/usr/bin/env bash
# Optimize global decomposition across nested WRF domains using smart tile scoring and optional grid perturbations

set -euo pipefail
IFS=$'\n\t'

# --- Default Parameters ---
enable_parallel_io=false
disable_grid_perturb=false
nests=1
nio_groups=""
nio_tasks_per_group=""
cores_per_node=128
max_nodes=1
spacing_list=()
length_we_list=()
length_sn_list=()
we_list=()
sn_list=()

min_tile=10
perturb_percent=10

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-parallel-io) enable_parallel_io=true; shift ;;
    --disable-grid-perturb) disable_grid_perturb=true; shift ;;
    --nests) nests=$2; shift 2 ;;
    --spacing) IFS=',' read -r -a spacing_list <<< "$2"; shift 2 ;;
    --length-we) IFS=',' read -r -a length_we_list <<< "$2"; shift 2 ;;
    --length-sn) IFS=',' read -r -a length_sn_list <<< "$2"; shift 2 ;;
    --we) IFS=',' read -r -a we_list <<< "$2"; shift 2 ;;
    --sn) IFS=',' read -r -a sn_list <<< "$2"; shift 2 ;;
    --nio-groups) nio_groups=$2; shift 2 ;;
    --nio-tasks-per-group) nio_tasks_per_group=$2; shift 2 ;;
    --cores-per-node) cores_per_node=$2; shift 2 ;;
    --max-nodes) max_nodes=$2; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Recommend NIO setup if enabled ---
if [[ "$enable_parallel_io" == true ]]; then
  if [[ -z $nio_groups && -z $nio_tasks_per_group ]]; then
    for setting in "1x2" "2x2" "2x4" "4x2"; do
      g=${setting%x*}
      t=${setting#*x}
      total_io=$(( g * t ))
      compute=$(( cores_per_node - total_io ))
      (( compute > 0 )) || continue
      nio_groups=$g
      nio_tasks_per_group=$t
      break
    done
  else
    [[ -z $nio_groups ]] && nio_groups=$nests
    [[ -z $nio_tasks_per_group ]] && nio_tasks_per_group=2
  fi
else
  nio_groups=0
  nio_tasks_per_group=0
fi

# --- Derive grid sizes ---
declare -a base_we_list base_sn_list perturb_range final_we_list final_sn_list
for ((i=0; i<nests; i++)); do
  if [[ -n ${we_list[i]:-} && -n ${sn_list[i]:-} ]]; then
    base_we_list[i]=${we_list[i]}
    base_sn_list[i]=${sn_list[i]}
  else
    spacing=${spacing_list[i]:-1}
    we_km=${length_we_list[i]:-0}
    sn_km=${length_sn_list[i]:-$we_km}
    base_we_list[i]=$(awk "BEGIN {print int($we_km * 1000 / $spacing)}")
    base_sn_list[i]=$(awk "BEGIN {print int($sn_km * 1000 / $spacing)}")
  fi
  (( base_we_list[i] == 0 || base_sn_list[i] == 0 )) && { echo "Missing grid dimensions for nest $((i+1))"; exit 1; }
  perturb_range[i]=$(awk -v val=${base_we_list[i]} -v p=$perturb_percent 'BEGIN{printf "%d", val * p / 100}')

  if [[ "$disable_grid_perturb" == true ]]; then
    perturb_range[i]=0
  fi

done

# --- Evaluate decompositions ---
echo -e "\nOptimizing tiling from 1 to $max_nodes nodes..."
best_overall_score=0
best_overall_summary=""
declare -a valid_summaries
all_failed=true

for nodes in $(seq 1 $max_nodes); do
  total_cores=$((nodes * cores_per_node))
  io_cores=$((nio_groups * nio_tasks_per_group))
  compute_cores=$((total_cores - io_cores))

  best_score=0
  best_layout=""
  best_tile_sizes=""
  best_grid_sizes=""

  for ((npx=1; npx<=compute_cores; npx++)); do
    (( compute_cores % npx == 0 )) || continue
    npy=$((compute_cores / npx))

    if [[ "$enable_parallel_io" == true ]]; then
      (( npy < nio_tasks_per_group )) && continue
      (( npy % nio_tasks_per_group != 0 )) && continue
    fi

    (( npx * npy > compute_cores )) && continue

    valid=true
    unset tx1 ty1 tx2 ty2
    unset we_out1 sn_out1 we_out2 sn_out2

    for ((i=0; i<nests; i++)); do
      base_we=${base_we_list[i]}
      base_sn=${base_sn_list[i]}

      delta_we=${perturb_range[i]}
      delta_sn=${perturb_range[i]}
      we_start=$((base_we - delta_we))
      we_end=$((base_we + delta_we))
      sn_start=$((base_sn - delta_sn))
      sn_end=$((base_sn + delta_sn))

      best_local_score=0
      found_valid=false

      for ((we=we_start; we<=we_end; we++)); do
        for ((sn=sn_start; sn<=sn_end; sn++)); do
          tx=$(( we / npx ))
          ty=$(( sn / npy ))
          if (( tx < min_tile || ty < min_tile )); then
            continue
          fi
          score=$(awk -v tx=$tx -v ty=$ty 'BEGIN{ar=tx/ty; print (tx*ty)/(1 + ((ar-1)^2))}')
          better=$(awk -v s=$score -v b=$best_local_score 'BEGIN {print (s > b) ? 1 : 0}')
          if [[ "$better" == "1" ]]; then
            best_local_score=$score
            if (( i == 0 )); then tx1=$tx; ty1=$ty; we_out1=$we; sn_out1=$sn; fi
            if (( i == 1 )); then tx2=$tx; ty2=$ty; we_out2=$we; sn_out2=$sn; fi
            found_valid=true
          fi
        done
      done

      [[ "$found_valid" == false ]] && valid=false
    done

    [[ "$valid" == false ]] && continue

    for ((i=0; i<nests; i++)); do
      ew=$( (( i == 0 )) && echo $we_out1 || echo $we_out2 )
      sn=$( (( i == 0 )) && echo $sn_out1 || echo $sn_out2 )
      layout_x=$npx
      layout_y=$npy

      tile_x=$(( ew / layout_x ))
      tile_y=$(( sn / layout_y ))
      if (( tile_x < min_tile || tile_y < min_tile )); then
        valid=false
        break
      fi
    done

    [[ "$valid" == false ]] && continue

    score=$(awk -v tx1=${tx1:-1} -v ty1=${ty1:-1} -v tx2=${tx2:-1} -v ty2=${ty2:-1} -v n=$nests '
      BEGIN {
        if (n == 1) {
          ar1 = tx1 / ty1;
          score = (tx1 * ty1) / (1 + (ar1 - 1)^2);
        } else {
          ar1 = tx1 / ty1;
          ar2 = tx2 / ty2;
          ar_diff = sqrt((ar1 - 1)^2 + (ar2 - 1)^2);
          avg_area = (tx1 * ty1 + tx2 * ty2) / 2;
          score = avg_area / (1 + ar_diff^2);
        }
        printf "%.1f", score;
      }')

    better=$(awk -v s=$score -v b=$best_score 'BEGIN {print (s > b) ? 1 : 0}')
    if [[ "$better" == "1" ]]; then
      best_score=$score
      best_layout="$npx x $npy"
      if (( nests == 1 )); then
        best_tile_sizes="d01: ${tx1}x${ty1}"
        best_grid_sizes="d01: ${we_out1}x${sn_out1}"
      else
        best_tile_sizes="d01: ${tx1}x${ty1}, d02: ${tx2}x${ty2}"
        best_grid_sizes="d01: ${we_out1}x${sn_out1}, d02: ${we_out2}x${sn_out2}"
      fi
    fi
  done

  if [[ -n "$best_layout" ]]; then
    summary=$(printf "✅ Nodes: %2d  Cores: %4d  Compute Ranks: %4d  →  Layout: %-10s  | %-25s | Grid: %-20s | NIO: %dx%d | score=%s" \
      "$nodes" "$total_cores" "$compute_cores" "$best_layout" "$best_tile_sizes" "$best_grid_sizes" "$nio_groups" "$nio_tasks_per_group" "$best_score")
    valid_summaries+=("$best_score|$summary")
    all_failed=false
  else
    printf "🚫 Nodes: %2d  Cores: %4d  Compute Ranks: %4d  →  No valid layout found\n" \
      "$nodes" "$total_cores" "$compute_cores"
  fi

done

if (( ${#valid_summaries[@]} > 0 )); then
  echo -e "\nSorted Valid Layouts by Score:"
  printf "%s\n" "${valid_summaries[@]}" | sort -nr -t '|' -k1 | cut -d'|' -f2-
elif [[ "$enable_parallel_io" == true ]]; then
  echo -e "\n⚠️  No valid decompositions found. Consider adjusting --nio-tasks-per-group (e.g., try 2 or 4)."
fi
