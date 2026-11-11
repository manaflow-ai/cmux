#!/usr/bin/env bash
# retarget-then-merge-v2.sh PR HEAD PARENT: once PARENT reads MERGED, change only PR's base to
# feat-cmux-next (head must stay HEAD), then gated pinned merge via merge-on-ship-v3.
set -o pipefail; . "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmux; PR=$1; H=$2; P=$3
gw 0 -- glaeda-gh wait pr $R#$P --until merged --timeout 21600
S=$(gh pr view $P -R $R --json state --jq .state); echo "#$P state=$S"
[ "$S" = MERGED ] || { echo "HOLD: #$P not merged"; exit 3; }
gh api -X PATCH repos/$R/pulls/$PR -f base=feat-cmux-next --jq '"base=\(.base.ref) head=\(.head.sha)"'
sleep 30
CUR=$(gh api repos/$R/pulls/$PR --jq .head.sha); [ "$CUR" = "$H" ] || { echo "HOLD: #$PR head moved to $CUR"; exit 6; }
exec bash "$(dirname "$0")"/merge-on-ship-v4.sh "$PR" "$H"
