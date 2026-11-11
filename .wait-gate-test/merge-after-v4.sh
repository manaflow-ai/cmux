#!/usr/bin/env bash
# merge-after-v4.sh (v3 + every wait gated by wait-gate.sh) PR HEAD [PREREQ_PR...]
# 1. Each PREREQ_PR must read MERGED on GitHub (a timed-out wait is never taken as a merge).
# 2. If HEAD has no passing "React Doctor (changed React projects)" (a required check added
#    2026-11-11 12:27Z that older PR heads never ran), bring in base with GitHub update-branch
#    pinned to HEAD, and tell dep-fleet-6 the new head (base-only; merge_hold judges the carry).
# 3. CI done at the head, merge freeze exit 0 (2, unknown, holds like 1), then merge pinned.
set -o pipefail; . "$(dirname "$0")/wait-gate.sh"
R=manaflow-ai/cmux; PR=$1; H=$2; shift 2
WT=${MERGE_WT:-/home/leo/.wt/checkouts/cmux/fix--acpmux-gated-filters-capability}
RD='React%20Doctor%20(changed%20React%20projects)'
for PRE in "$@"; do
  gw 0 -- glaeda-gh wait pr $R#$PRE --until merged --timeout 21600
  S=$(gh pr view $PRE -R $R --json state --jq .state 2>&1); echo "#$PRE state=$S"
  [ "$S" = MERGED ] || { echo "HOLD: #$PRE not merged; #$PR not merged"; exit 3; }
done
CUR=$(gh api repos/$R/pulls/$PR --jq .head.sha 2>&1)
[ "$CUR" = "$H" ] || { echo "HOLD: #$PR head is $CUR, not $H; not merged"; exit 6; }
rd=$(gh api "repos/$R/commits/$H/check-runs?check_name=$RD" --jq '[.check_runs[].conclusion]|join(",")' 2>&1)
echo "react doctor at ${H:0:10}: [$rd]"
# Only a head that predates the workflow (added 2026-11-11T12:27Z) never runs it; a newer head
# with no run yet is still queued, and a failure is a verdict, not a missing run.
cd_=$(gh api repos/$R/commits/$H --jq .commit.committer.date 2>&1)
echo "head committed $cd_"
if [ -z "$rd" ] && [[ "$cd_" < "2026-11-11T12:27:00Z" ]]; then
  gh api -X PUT repos/$R/pulls/$PR/update-branch -f expected_head_sha=$H --jq .message 2>&1 | tail -1
  NEW=$H
  for _ in 1 2 3 4 5 6; do sleep 20; NEW=$(gh api repos/$R/pulls/$PR --jq .head.sha); [ "$NEW" != "$H" ] && break; done
  [ "$NEW" != "$H" ] || { echo "HOLD: update-branch did not move #$PR"; exit 5; }
  echo "new head $NEW"
  printf 'cmux#%s: brought in base (update-branch, base-only) so the new required React Doctor check runs. New head: %s (was %s). I merge pinned there once CI is green and merge_hold carries your SHIP.\n' "$PR" "$NEW" "$H" \
    | reach gcp-agent-lane-2 'acpmux send --no-wait --from huge-blue/acpmux-outbound-volume dep-fleet-6 -'
  H=$NEW
fi
gw 0,1 -- glaeda-gh wait pr $R#$PR --until done --sha $H --timeout 5400
MS=$(gh api repos/$R/pulls/$PR --jq .mergeable_state 2>&1)
[ "$MS" = dirty ] && { echo "HOLD: #$PR conflicts with its base (mergeable_state dirty); not merged"; exit 7; }
(cd $WT && python3 scripts/ci/merge_freeze.py check --repo $R --pr $PR --base feat-cmux-next >/dev/null 2>&1); F=$?
echo "freeze_exit=$F"
[ "$F" = 0 ] || { echo "HOLD: merge freeze exit $F; #$PR not merged"; exit 4; }
timeout 600 gh pr merge $PR --repo $R --squash --match-head-commit $H 2>&1 | tail -4; M=$?; echo merge_exit=$M
gh pr view $PR -R $R --json state --jq '"#'$PR' \(.state)"'
[ "$M" = 0 ] || exit "$M"
