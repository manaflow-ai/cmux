set -u
cd webviews
P="test/agent-history.test.ts test/agent-pane-activity-line.test.ts test/agent-pane-adopted-edited-files.test.ts test/agent-pane-agents-pill.test.ts test/agent-pane-chat-width.test.ts test/agent-pane-goal-strip-column.test.ts"
G="test/agent-pane-bottom-stack-edges.test.ts test/agent-pane-column-edges.test.ts test/agent-pane-fold-keeps-place.test.ts test/agent-pane-messages-presentation.test.ts test/accent-glass-invariants-1.test.ts test/browser/gallery-control-surfaces-4.test.ts"
for mode in 0 1; do
  out="$FAST_CHECKS_OUT/dur-$mode.json"
  s=$(date +%s)
  CMUX_WEB_TEST_JOBS=1 CMUX_WEB_TEST_DEV_JOBS=1 CMUX_WEB_TEST_SHARED_SERVERS=$mode CMUX_WEB_TEST_RETRIES=0 CMUX_WEB_TEST_DURATIONS_OUT="$out" \
    bash ../scripts/ci/run-webviews-tests.sh $P $G > "$FAST_CHECKS_OUT/run-$mode.log" 2>&1; rc=$?
  echo "MODE shared=$mode rc=$rc wall=$(( $(date +%s) - s ))s"
  cat "$out"; echo
  grep -E "^(FAIL|TIMEOUT|###)" "$FAST_CHECKS_OUT/run-$mode.log"
done
