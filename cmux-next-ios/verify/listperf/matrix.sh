#!/usr/bin/env bash
# The phase-1 scroll matrix: every vertical list at a realistic size, idle and with live
# updates, plus the rebuilt Feed as the reference. Each line is one `rig.sh run`; set
# REPS (default 2) for repeats, ONLY=<label-prefix> to run a subset.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
reps=${REPS:-2}
runs=(
  "feed-ref        feed        FEED_STRESS=320"
  "ws-200          workspaces  LIST_COUNT=200"
  "ws-200-live4    workspaces  LIST_COUNT=200 LIST_LIVE_HZ=4"
  "home-300        home        LIST_COUNT=300"
  "chat-40         chat        LIST_COUNT=40"
  "chat-40-small   chat        LIST_COUNT=40 LIST_LARGE_DIFF=0"
  "chat-200        chat        LIST_COUNT=200"
  "chat-40-stream  chat        LIST_COUNT=40 LIST_STREAM=1"
  "tabs-30         tabs        LIST_COUNT=30"
  "tabs-30-stream  tabs        LIST_COUNT=30 LIST_STREAM=1"
  "diff-2400       diff        LIST_COUNT=3"
  "diff-2400-pan   diff        LIST_COUNT=3 LIST_PAN=1 LIST_PASSES=4 LIST_SPEED=800"
  "artifacts-40    artifacts   LIST_COUNT=40"
)
for rep in $(seq 1 "$reps"); do
  for line in "${runs[@]}"; do
    read -r label screen args <<<"$line"
    [[ -n "${ONLY:-}" && $label != ${ONLY}* ]] && continue
    echo "== $label r$rep"
    # shellcheck disable=SC2086
    "$here/rig.sh" run "$label-r$rep" "$screen" $args | grep -E 'POOLED|-down-|-up-|-open' || echo "$label r$rep: no windows"
  done
done
