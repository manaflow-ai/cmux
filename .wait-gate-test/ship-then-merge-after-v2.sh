#!/usr/bin/env bash
# ship-then-merge-after-v2.sh PR HEAD [PREREQ...]: wait for a SHIP receipt at HEAD, then merge-after-v3 with prereqs.
. "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmux; PR=$1; H=$2; shift 2
gw 0 -- glaeda-gh wait comment $R#$PR --match "SHIP at $H" --since 24h --timeout 14400
n=$(gh api graphql -f query='query{repository(owner:"manaflow-ai",name:"cmux"){pullRequest(number:'$PR'){comments(last:60){nodes{body}}}}}' --jq "[.data.repository.pullRequest.comments.nodes[]|select(.body|test(\"SHIP at $H\"))]|length")
[ "${n:-0}" -ge 1 ] || { echo "HOLD: no SHIP at $H on #$PR"; exit 8; }
exec bash "$(dirname "$0")"/merge-after-v4.sh "$PR" "$H" "$@"
