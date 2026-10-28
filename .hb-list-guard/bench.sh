#!/bin/bash
# Scratch (never committed): release daemon, 2800 chats (a 14.7 MB list), three stale
# clients reconnecting at 1 Hz for SECS; daemon CPU from /proc. Base, then this branch.
set -uo pipefail
ROOT=$PWD; B=$ROOT/.hb-list-guard; SECS=${HB_SECS:-180}; N=${HB_SESSIONS:-2800}
export CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
TCK=$(getconf CLK_TCK); cd "$ROOT/cmux-tui"; A=crates/acpmux/src
mkdir -p "$B/after"; for f in hub/mod.rs hub/seen.rs hub/session_pages.rs hub/lifecycle.rs hub/remote_rows.rs server/mod.rs server/requests.rs hub/list_guard.rs server/list_reply.rs; do mkdir -p "$B/after/$(dirname $f)"; cp "$A/$f" "$B/after/$f"; done
ticks() { awk '{print $14+$15}' "/proc/$1/stat"; }
side() {
  local name=$1
  if [ "$name" = before ]; then
    for f in hub/mod.rs hub/seen.rs hub/session_pages.rs hub/lifecycle.rs hub/remote_rows.rs server/mod.rs server/requests.rs; do cp "$B/base/$f" "$A/$f"; done
    rm -f $A/hub/list_guard.rs $A/server/list_reply.rs
  else
    for f in hub/mod.rs hub/seen.rs hub/session_pages.rs hub/lifecycle.rs hub/remote_rows.rs server/mod.rs server/requests.rs hub/list_guard.rs server/list_reply.rs; do cp "$B/after/$f" "$A/$f"; done
  fi
  cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -1
  local s; s=$(mktemp -d /tmp/hb-lg-XXXX); python3 "$B/seed.py" "$s/home" "$N"; mkdir -p "$s/h"
  env -i HOME="$s/h" PATH=/usr/bin:/bin ACPMUX_HOME="$s/home" ACPMUX_SOCKET="$s/s.sock" ACPMUX_LOGIN_ENV=0 \
    ACPMUX_AGENT_LAUNCH=deny "${CARGO_TARGET_DIR:-target}/release/acpmux" daemon run --ready-fd 3 --log warn 3>"$s/ready" >"$s/d.log" 2>&1 &
  for _ in $(seq 600); do grep -q ready "$s/ready" 2>/dev/null && break; sleep 0.5; done
  local pid; pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$s/ready")
  sleep 10
  local i0; i0=$(ticks $pid); sleep 30; local i1; i1=$(ticks $pid)
  echo "RESULT $name idle 30s: $(awk -v d=$((i1-i0)) -v t=$TCK 'BEGIN{printf "%.2f%%", d/t/30*100}')"
  python3 "$B/stale.py" "$s/s.sock" $((SECS+20)) &
  local cp=$!; sleep 15
  local t0; t0=$(ticks $pid); sleep "$SECS"; local t1; t1=$(ticks $pid)
  echo "RESULT $name 3 stale clients ${SECS}s: $(awk -v d=$((t1-t0)) -v t=$TCK -v s=$SECS 'BEGIN{printf "%.2f%%", d/t/s*100}') rss_kb=$(awk '/VmRSS/{print $2}' /proc/$pid/status)"
  wait $cp; kill $pid; sleep 1; rm -rf "$s"
}
side before
side after
