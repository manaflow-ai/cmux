set -u
cd webviews
nproc; free -g | head -2
F="test/agent-history.test.ts test/agent-pane-activity-line.test.ts test/agent-pane-adopted-edited-files.test.ts test/agent-pane-adopted-tool-calls.test.ts test/agent-pane-agents-pill.test.ts test/agent-pane-bottom-stack-edges.test.ts test/agent-pane-chat-width.test.ts test/agent-pane-column-edges.test.ts test/agent-pane-fold-keeps-place.test.ts test/agent-pane-goal-strip-column.test.ts test/agent-pane-messages-presentation.test.ts"
for mode in 0 1 0 1; do
  s=$(date +%s)
  CMUX_WEB_TEST_JOBS=8 CMUX_WEB_TEST_DEV_JOBS=4 CMUX_WEB_TEST_SHARED_SERVERS=$mode CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh $F > /tmp/out-$mode.log 2>&1; rc=$?
  echo "MODE shared=$mode rc=$rc wall=$(( $(date +%s) - s ))s"
  grep -E "^(PASS|FAIL|TIMEOUT|shared dev|###)" /tmp/out-$mode.log | head -30
done
grep -h "test dev hub" /tmp/out-1.log | sort | uniq -c | head
grep -A40 "^::group::" /tmp/out-1.log | head -120
