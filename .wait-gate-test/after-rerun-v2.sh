#!/usr/bin/env bash
# after-rerun-v2.sh REPO RUN PR HEAD: wait for a rerun to finish, then the gated pinned merge.
set -o pipefail; . "$(dirname "$0")/wait-gate.sh"
REPO=$1 RUN=$2 PR=$3 H=$4
gw 0,1 -- glaeda-gh wait run $REPO/$RUN --until done --timeout 3600
if [ "$REPO" = manaflow-ai/cmux ]; then exec bash "$(dirname "$0")"/merge-after-v4.sh "$PR" "$H"; fi
[ "$(git ls-remote https://github.com/$REPO.git refs/pull/$PR/head | cut -f1)" = "$H" ] || { echo "HOLD: #$PR head moved"; exit 6; }
gw 0 -- glaeda-gh wait pr $REPO#$PR --until done --sha $H --timeout 3600
timeout 600 gh pr merge $PR --repo $REPO --squash --match-head-commit $H 2>&1 | tail -3; M=${PIPESTATUS[0]}; echo merge_exit=$M
gh pr view $PR -R $REPO --json state --jq '"#'$PR' \(.state)"'; exit $M
