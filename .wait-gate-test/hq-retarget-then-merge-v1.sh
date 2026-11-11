#!/usr/bin/env bash
# hq-retarget-then-merge-v1.sh PR HEAD PARENT: once PARENT reads MERGED (a failed wait stops first),
# retarget PR to main, check its head is still HEAD, then the gated hq merge on SHIP at HEAD.
set -o pipefail; . "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmuxterm-hq; PR=$1; H=$2; P=$3
gw 0 -- glaeda-gh wait pr $R#$P --until merged --timeout 21600
S=$(gh pr view $P -R $R --json state --jq .state); echo "#$P state=$S"
[ "$S" = MERGED ] || { echo "HOLD: #$P not merged"; exit 3; }
ID=$(gh api graphql -f query='query{repository(owner:"manaflow-ai",name:"cmuxterm-hq"){pullRequest(number:'$PR'){id}}}' --jq .data.repository.pullRequest.id)
gh api graphql -f query='mutation($id:ID!){updatePullRequest(input:{pullRequestId:$id,baseRefName:"main"}){pullRequest{baseRefName headRefOid}}}' -f id=$ID --jq .data.updatePullRequest.pullRequest
sleep 30
CUR=$(git ls-remote https://github.com/$R.git refs/pull/$PR/head | cut -f1)
[ "$CUR" = "$H" ] || { echo "HOLD: #$PR head moved to $CUR after retarget; not merged (send for a carry)"; exit 6; }
exec bash "$(dirname "$0")"/hq-ship-merge-v2.sh "$PR" "$H"
