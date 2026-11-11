#!/usr/bin/env bash
# test_wait_gate.sh: every wait-then-act script stops (non-zero, no retarget/merge/update-branch call)
# when a glaeda-gh wait times out (2), is down (3), conflicts (4) or sees nothing (6); and a CI wait
# that ends red (1) still reaches merge_hold's classifier (the merge call). Fakes on PATH; no network.
B=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=1111111111111111111111111111111111111111; fail=0
mkdir -p "$T/bin"
cat > "$T/bin/glaeda-gh" <<'F'
#!/usr/bin/env bash
echo "glaeda-gh $*" >> "$LOG"
case "$*" in *"--until merged"*) c=${WAIT_MERGED:-0};; *"wait comment"*) c=${WAIT_COMMENT:-0};; *"wait run"*) c=${WAIT_RUN:-0};; *) c=${WAIT_CI:-0};; esac
echo "fake wait exit $c"; exit $c
F
cat > "$T/bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >> "$LOG"
case "$*" in
  *"pr view"*state*) echo "${PARENT_STATE:-OPEN}";;
  *"pr merge"*) echo merged; exit 0;;
  *graphql*comments*|*"/comments"*) echo 1;;
  *mergeable_state*) echo clean;;
  *check-runs*) echo success;;
  *head.sha*|*'"base='*) echo "$FAKE_HEAD";;
  *graphql*) echo '{}';;
esac
exit 0
F
cat > "$T/bin/git" <<'F'
#!/usr/bin/env bash
[ "$1" = ls-remote ] && { printf '%s\trefs/x\n' "$FAKE_HEAD"; exit 0; }; exit 0
F
for n in reach python3 sleep; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$n"; done
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_HEAD=$H MERGE_WT=$T
ACTS='pulls/[0-9]+ -f base|-X PATCH|updatePullRequest|pr merge|update-branch'
# run NAME WANT(stop|merge) ENV... -- SCRIPT ARGS
run() {
  local name=$1 want=$2; shift 2; local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  export LOG="$T/$name.log"; : > "$LOG"
  env "${envs[@]}" bash "$@" > "$T/$name.out" 2>&1; local rc=$?
  local acted=0; grep -qE "$ACTS" "$LOG" && acted=1
  if [ "$want" = stop ] && { [ $rc = 0 ] || [ $acted = 1 ]; }; then
    echo "FAIL $name: rc=$rc acted=$acted"; sed 's/^/  /' "$T/$name.out" "$LOG"; fail=1
  elif [ "$want" = merge ] && { [ $rc != 0 ] || ! grep -q 'pr merge' "$LOG"; }; then
    echo "FAIL $name: wanted a merge call, rc=$rc"; sed 's/^/  /' "$T/$name.out" "$LOG"; fail=1
  else echo "ok   $name (rc=$rc)"; fi
}
for c in 2 3 6; do
  run retarget-parent-wait-$c stop WAIT_MERGED=$c PARENT_STATE=OPEN -- "$B/retarget-then-merge-v2.sh" 41295 $H 41240
  # even if GitHub then reads MERGED, a failed wait stops the job: the job never acts past a failed wait
  run retarget-parent-wait-$c-merged stop WAIT_MERGED=$c PARENT_STATE=MERGED -- "$B/retarget-then-merge-v2.sh" 41295 $H 41240
  run prereq-wait-$c stop WAIT_MERGED=$c -- "$B/merge-after-v4.sh" 41427 $H 41418
  run ship-wait-$c stop WAIT_COMMENT=$c -- "$B/merge-on-ship-v4.sh" 41392 $H
  run ship-then-wait-$c stop WAIT_COMMENT=$c -- "$B/ship-then-merge-after-v2.sh" 41427 $H 41418
  run hq-ship-wait-$c stop WAIT_COMMENT=$c -- "$B/hq-ship-merge-v2.sh" 9478 $H
  run hq-ci-wait-$c stop WAIT_CI=$c -- "$B/hq-ship-merge-v2.sh" 9478 $H
  run rerun-wait-$c stop WAIT_RUN=$c -- "$B/after-rerun-v2.sh" manaflow-ai/cmux 1 41327 $H
  run hq-rerun-ci-wait-$c stop WAIT_CI=$c -- "$B/after-rerun-v2.sh" manaflow-ai/cmuxterm-hq 1 9478 $H
  run hq-retarget-parent-wait-$c stop WAIT_MERGED=$c PARENT_STATE=MERGED -- "$B/hq-retarget-then-merge-v1.sh" 9548 $H 9521
done
for c in 2 3 4 6; do run cmux-ci-wait-$c stop WAIT_CI=$c -- "$B/merge-after-v4.sh" 41392 $H; done
run parent-open-after-ok-wait stop PARENT_STATE=OPEN -- "$B/retarget-then-merge-v2.sh" 41295 $H 41240
# controls: the happy path still merges, and a red CI wait still reaches the merge call (merge_hold classifies it)
run happy-retarget merge PARENT_STATE=MERGED -- "$B/retarget-then-merge-v2.sh" 41295 $H 41240
run happy-merge-after merge PARENT_STATE=MERGED -- "$B/merge-after-v4.sh" 41427 $H 41418
run red-ci-reaches-classifier merge WAIT_CI=1 -- "$B/merge-after-v4.sh" 41392 $H
run happy-hq merge -- "$B/hq-ship-merge-v2.sh" 9478 $H
run hq-retarget-parent-open stop PARENT_STATE=OPEN -- "$B/hq-retarget-then-merge-v1.sh" 9548 $H 9521
run happy-hq-retarget merge PARENT_STATE=MERGED -- "$B/hq-retarget-then-merge-v1.sh" 9548 $H 9521
exit $fail
