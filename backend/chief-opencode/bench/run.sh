#!/usr/bin/env bash
# Runs on the Freestyle VM (freestyle-run.sh --sync <this dir>): installs the pinned opencode v2 CLI
# once, then plays the scenario through the cmux-chief plugin. Outputs go to $ARTIFACTS_DIR.
set -euo pipefail
cd "$(dirname "$0")"
OC_VERSION="${OC_VERSION:-2.0.29}"
# Its own prefix: the VM image may carry an older opencode on PATH.
PREFIX=/opt/oc2
if [ "$(cat "$PREFIX/version" 2>/dev/null)" != "$OC_VERSION" ]; then
  t0=$(date +%s%N)
  mkdir -p "$PREFIX"
  npm install --prefix "$PREFIX" --no-fund --no-audit "@opencode/cli@${OC_VERSION}" 2>&1 | tail -20
  echo "$OC_VERSION" > "$PREFIX/version"
  echo "install_ms=$(( ($(date +%s%N) - t0) / 1000000 ))"
fi
export OPENCODE_BIN="$PREFIX/node_modules/.bin/opencode"
"$OPENCODE_BIN" --version || true
# A server left by an earlier run on this (reused) VM would answer instead of the new one.
pkill -f "opencode serve --hostname 127.0.0.1 --port 4096" || true
out="${ARTIFACTS_DIR:-/work/artifacts}/${BENCH_TAG:-o-bench}"
mkdir -p "$out"
case "${1:-scenario}" in
  probe) timeout 600 bun drive.ts probe.json "$out" ;;
  *) timeout 1500 bun drive.ts scenario.json "$out" ;;
esac
