#!/bin/bash
# Bench (not part of the PR): acpmux daemon CPU with 2800 sessions and three
# chat-notices watchers, base then fix, same job, same harness.
set -euo pipefail
ROOT=$PWD
B=$ROOT/.hb-bench
SECS=${HB_SECS:-300}
N=${HB_SESSIONS:-2800}
export CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
TCK=$(getconf CLK_TCK)
cd "$ROOT/cmux-tui"
ticks() { awk '{print $14+$15}' "/proc/$1/stat"; }
install_side() {
  local side=$1
  if [ "$side" = before ]; then
    cp "$B/base/rpc.rs" crates/acpmux/src/rpc.rs
    cp "$B/base/session_pages.rs" crates/acpmux/src/hub/session_pages.rs
    cp "$B/base/agent_chat_notices.rs" crates/cmux-tui-core/src/mux/agent_chat_notices.rs
  else
    cp "$B/fix/rpc.rs" crates/acpmux/src/rpc.rs
    cp "$B/fix/session_pages.rs" crates/acpmux/src/hub/session_pages.rs
    cp "$B/fix/agent_chat_notices.rs" crates/cmux-tui-core/src/mux/agent_chat_notices.rs
  fi
  printf '\n#[cfg(test)]\n#[path = "%s"]\nmod hb_bench;\n' "$B/harness.rs" >> crates/cmux-tui-core/src/mux/agent_chat_notices.rs
}
measure() {
  local side=$1
  install_side "$side"
  echo "== $side: build"
  cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -2
  cargo test --locked -p cmux-tui-core --lib --no-run 2>&1 | tail -2
  local scratch; scratch=$(mktemp -d /tmp/hb-bench-XXXX)
  python3 "$B/seed.py" "$scratch/home" "$N"
  mkdir -p "$scratch/h"
  env -i HOME="$scratch/h" PATH=/usr/bin:/bin ACPMUX_HOME="$scratch/home" ACPMUX_SOCKET="$scratch/s.sock" \
    ACPMUX_AGENT_LAUNCH=deny ACPMUX_TEST_SESSION_TMP_BASE="$scratch/st" \
    "${CARGO_TARGET_DIR:-target}/release/acpmux" daemon run --ready-fd 3 --log info 3>"$scratch/ready" > "$scratch/daemon.log" 2>&1 &
  local dpid=$!
  for _ in $(seq 600); do grep -q ready "$scratch/ready" 2>/dev/null && break; kill -0 $dpid 2>/dev/null || break; sleep 0.5; done
  echo "ready: $(cat "$scratch/ready" 2>/dev/null) alive: $(kill -0 $dpid 2>/dev/null && echo yes || echo no)"
  local rpid; rpid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$scratch/ready")
  echo "spawned pid $dpid, ready pid $rpid"; dpid=$rpid
  python3 "$B/probe.py" "$scratch/s.sock"
  sleep 10
  local i0; i0=$(ticks $dpid); sleep 60; local i1; i1=$(ticks $dpid)
  echo "RESULT $side idle-no-watchers 60s cpu=$(awk -v d=$((i1-i0)) -v t=$TCK 'BEGIN{printf "%.2f%%", d/t/60*100}')"
  HB_BENCH_SOCKET="$scratch/s.sock" HB_BENCH_SECS=$((SECS+40)) \
    cargo test --locked -p cmux-tui-core --lib hb_bench_watchers -- --ignored --nocapture > "$scratch/harness.log" 2>&1 &
  local hpid=$!
  sleep 30
  local t0; t0=$(ticks $dpid); local prev=$t0; local samples=""
  for _ in $(seq $((SECS/30))); do
    sleep 30; local now; now=$(ticks $dpid)
    samples="$samples $(awk -v d=$((now-prev)) -v t=$TCK 'BEGIN{printf "%.1f", d/t/30*100}')"; prev=$now
  done
  local t1=$prev
  echo "RESULT $side 3-watchers ${SECS}s cpu=$(awk -v d=$((t1-t0)) -v t=$TCK -v s=$SECS 'BEGIN{printf "%.2f%%", d/t/s*100}') samples30s:$samples rss_kb=$(awk '/VmRSS/{print $2}' /proc/$dpid/status)"
  wait $hpid || echo "harness exit $?"
  tail -3 "$scratch/harness.log"
  kill $dpid; sleep 2
  grep -c . "$scratch/daemon.log" || true
  rm -rf "$scratch"
}
measure before
measure after
