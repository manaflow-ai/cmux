# Harness: one webview shard as ci-web.yml's "Test webviews" step runs it, timed.
# bash .wvpack-shard.sh SHARD COUNT SHARED(0|1) [SHARE]
set -u
shard="$1" count="$2" shared="$3" share="${4:-vite}"
bash scripts/ci/ensure-web-bundles.sh > /tmp/wvpack-ensure.log 2>&1 || { echo "ensure-web-bundles failed"; tail -20 /tmp/wvpack-ensure.log; }
cd webviews
(bun install --frozen-lockfile > /tmp/wvpack-install.log 2>&1) || tail -20 /tmp/wvpack-install.log
echo "nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G GITHUB_ACTIONS=${GITHUB_ACTIONS:-} chs=${CMUX_CHROME_HEADLESS_SHELL:-}"
export CMUX_NEXT_STYLE_GUARDS=warn CMUX_WEB_TEST_SHARD="$shard" CMUX_WEB_TEST_SHARD_COUNT="$count" \
  CMUX_WEB_TEST_RETRY_BUDGET=1920 CMUX_WEB_TEST_RETRY_DEADLINE=1920 CMUX_WEB_TEST_JOBS=8 CMUX_WEB_TEST_DEV_JOBS=4 \
  CMUX_WEB_TEST_DURATIONS="$PWD/../.wvpack-manifest.json" CMUX_WEB_TEST_SHARED_SERVERS="$shared" CMUX_WEB_TEST_HUB_SHARE="$share" \
  CMUX_WEB_TEST_RAW_LOG_DIR="${FAST_CHECKS_OUT:-/tmp}/raw-$shard"
start=$(date +%s)
bash ../scripts/ci/run-webviews-tests.sh > /tmp/wvpack-run.log 2>&1; rc=$?
wall=$(( $(date +%s) - start ))
echo "HARNESS shard=$shard/$count shared=$shared share=$share rc=$rc wall_s=$wall"
grep -E "^(running|shared dev|### webviews|passed only|  test/|FAIL |TIMEOUT |retry )" /tmp/wvpack-run.log | head -60
grep -h "test dev hub: own" /tmp/wvpack-run.log | sort | uniq -c | sort -rn | head
cp /tmp/wvpack-run.log "${FAST_CHECKS_OUT:-/tmp}/run-$shard-$shared.log" 2>/dev/null || true
exit 0
