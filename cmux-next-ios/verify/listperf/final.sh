#!/usr/bin/env bash
# The final before/after comparison: every case of matrix.sh on one host and one simulator,
# base and head alternating per case, REPS times (default 2). Base is the app built from the
# commit before the rebuild with this rig's files (DIR=smooth-base, PRODUCTS=build/base); head is
# this branch (DIR=smooth-lists). Labels: final-{base,head}-<case>-r<rep>.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
reps=${REPS:-2}
runs=(
  "ws-200          workspaces  LIST_COUNT=200"
  "ws-200-live4    workspaces  LIST_COUNT=200 LIST_LIVE_HZ=4"
  "ws-500-live8    workspaces  LIST_COUNT=500 LIST_LIVE_HZ=8"
  "home-300        home        LIST_COUNT=300"
  "chat-40         chat        LIST_COUNT=40"
  "chat-200        chat        LIST_COUNT=200"
  "chat-40-stream  chat        LIST_COUNT=40 LIST_STREAM=1"
  "chat-tall       chat        LIST_COUNT=3 LIST_TALL_ANSWER=1"
  "tabs-30         tabs        LIST_COUNT=30"
  "tabs-30-stream  tabs        LIST_COUNT=30 LIST_STREAM=1"
  "tabs-80         tabs        LIST_COUNT=80"
  "diff-2400       diff        LIST_COUNT=3"
  "diff-2400-pan   diff        LIST_COUNT=3 LIST_PAN=1 LIST_PASSES=4 LIST_SPEED=800"
  "artifacts-40    artifacts   LIST_COUNT=40"
  "feed-ref        feed        FEED_STRESS=320"
  "subagent-200       subagent    LIST_COUNT=200"
  "subagent-stream    subagent    LIST_COUNT=40 LIST_STREAM=1"
  "subagent-2000      subagent    LIST_COUNT=2000 LIST_PASSES=1"
  "subagents-list-60  subagents   LIST_COUNT=60 LIST_LIVE_HZ=4"
  "events-500         inspector   LIST_COUNT=500"
  "events-burst       inspector   LIST_COUNT=500 LIST_STREAM=1"
  "events-filter      inspector   LIST_COUNT=500 LIST_LIVE_HZ=20 LIST_FILTER=tool_call"
)
for rep in $(seq 1 "$reps"); do
  for line in "${runs[@]}"; do
    read -r label screen args <<<"$line"
    [[ -n "${ONLY:-}" && $label != ${ONLY}* ]] && continue
    for side in base head; do
      if [[ $side == base ]]; then dir=smooth-base products=build/base; else dir=smooth-lists products=build/demo; fi
      echo "== $side $label r$rep"
      # shellcheck disable=SC2086
      DIR=$dir PRODUCTS=$products "$here/rig.sh" run "final-$side-$label-r$rep" "$screen" $args \
        | grep -E 'POOLED|-open' || echo "$side $label r$rep: no windows"
    done
  done
done
