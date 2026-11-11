#!/usr/bin/env bash
# merge-on-ship.sh PR HEAD: merge only once a review SHIP receipt for the exact head is on the PR, then merge-after.
. "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmux; PR=$1; H=$2
gw 0 -- glaeda-gh wait comment $R#$PR --match "SHIP at $H" --since 24h --timeout 14400
n=$(gh api "repos/$R/issues/$PR/comments?per_page=100" --jq "[.[]|select(.body|test(\"SHIP at $H\"))]|length" 2>&1)
echo "SHIP receipts at ${H:0:10}: $n"
[ "$n" -ge 1 ] 2>/dev/null || { echo "HOLD: no SHIP receipt at $H on #$PR"; exit 8; }
exec bash "$(dirname "$0")"/merge-after-v4.sh "$PR" "$H"
