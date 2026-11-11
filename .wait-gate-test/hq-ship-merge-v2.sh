#!/usr/bin/env bash
# hq-ship-merge-v2.sh PR HEAD: wait for SHIP at HEAD on a cmuxterm-hq PR, check the head, CI, merge pinned.
. "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmuxterm-hq; PR=$1; H=$2
gw 0 -- glaeda-gh wait comment $R#$PR --match "SHIP at $H" --since 24h --timeout 14400
n=$(gh api "repos/$R/issues/$PR/comments?per_page=100" --jq "[.[]|select(.body|test(\"SHIP at $H\"))]|length" 2>/dev/null)
[ "${n:-0}" -ge 1 ] || n=$(gh api graphql -f query='query{repository(owner:"manaflow-ai",name:"cmuxterm-hq"){pullRequest(number:'$PR'){comments(last:60){nodes{body}}}}}' --jq "[.data.repository.pullRequest.comments.nodes[]|select(.body|test(\"SHIP at $H\"))]|length")
[ "${n:-0}" -ge 1 ] || { echo "HOLD: no SHIP at $H on #$PR"; exit 8; }
[ "$(git ls-remote https://github.com/$R.git refs/pull/$PR/head | cut -f1)" = "$H" ] || { echo "HOLD: #$PR head moved"; exit 6; }
gw 0 -- glaeda-gh wait pr $R#$PR --until done --sha $H --timeout 3600
timeout 600 gh pr merge $PR --repo $R --squash --match-head-commit $H 2>&1 | tail -3; M=${PIPESTATUS[0]}; echo merge_exit=$M
gh pr view $PR -R $R --json state --jq '"#'$PR' \(.state)"'; exit $M
