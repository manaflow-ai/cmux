#!/usr/bin/env bash
# Export one or more sessions' inbound messages in a time window as the trace that
# `hub::inbox_replay_tests::coordinator_surge_flood_admission` replays (ACPMUX_SURGE_TRACE).
#
#   export.sh FROM_ISO TO_ISO SESSION... > trace.json
#
# Run it on the machine whose daemon holds the sessions. It reads only acpmux's own event log
# (`acpmux session tail --json`), keeps arrival and turn-timing events, and cuts every message
# body down to its kind, PR numbers, runner label and urgency words: no other text leaves.
# With several sessions the arrivals are merged and the first session's turns give the reply
# timeline (the receiver whose reply rate decides the surge).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ms() { jq -n --arg t "$1" '$t | fromdateiso8601 * 1000'; }
from="$(ms "$1")"
to="$(ms "$2")"
shift 2
keep='"kind":"(user_message|queued|inbox|turn_started|turn_result|turn_end|turn_error|status|permission_[a-z]+)"'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
i=0
for session in "$@"; do
  acpmux session tail "$session" --json --last "${SURGE_TRACE_LAST:-200000}" \
    | grep -E "$keep" > "$tmp/$i.ndjson" || true
  jq -s --argjson from "$from" --argjson to "$to" --arg host "$session" \
    -f "$here/reduce.jq" "$tmp/$i.ndjson" > "$tmp/$i.json"
  i=$((i + 1))
done
jq -s '{
  sessions: map(.host),
  window: .[0].window,
  replyTimeline: .[0].replyTimeline,
  arrivals: (map(.arrivals) | add | unique_by(.promptId) | sort_by(.at)),
  textHints: (map(.textHints) | add),
  protectedIds: (map(.protectedIds) | add | unique)
}' "$tmp"/*.json
