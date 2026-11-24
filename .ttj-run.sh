set -euo pipefail
out=$(cd web 2>/dev/null && bash ../scripts/ci/ensure-system-chrome.sh 2>&1 || (cd webviews && bash ../scripts/ci/ensure-system-chrome.sh 2>&1))
echo "$out" | tail -3
export $(echo "$out" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -1)
echo "shell=$CMUX_CHROME_HEADLESS_SHELL"
cd webviews
CMUX_TURN_TRANSITION_DUMP="$FAST_CHECKS_OUT/ttj" bun test test/turn-transition-jumps.test.ts 2>&1 | tail -80
