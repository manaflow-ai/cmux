#!/usr/bin/env bash
# Bazel pilot: shared-cache and affected-test scenarios on the Rust builder.
# Usage: bazel/pilot_measure_rust_cache.sh LABEL CARGO_PKG
set -euo pipefail
PILOT=/work/bazel-pilot
SRC=$PILOT/src
LABEL="$1"; PKG="$2"
SHA="${PILOT_SHA:-89b472d502a1ec9936a978ba7ee7479b7d21cfd6}"
JOBS="${JOBS:-64}"
RESULTS=$PILOT/results.jsonl
export RUSTUP_HOME=/work/rust/rustup CARGO_HOME=$PILOT/cargo-home
export PATH=/work/rust/cargo/bin:/usr/local/bin:/usr/bin:/bin
export ZIG_GLOBAL_CACHE_DIR=$PILOT/zig-global
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang
export RUSTFLAGS="-C link-arg=-fuse-ld=mold"
export CMUX_TUI_BUILD_COMMIT="$SHA" CMUX_GIT_SHORT_SHA="${SHA:0:9}"
record() {
  local l; l=$(cut -d' ' -f1-3 /proc/loadavg)
  printf '{"host":"%s","tool":"%s","target":"%s","scenario":"%s","seconds":%s,"exit":%s,"load_before":"%s","load_after":"%s","cache":"%s","sha":"%s","jobs":%s,"at":"%s"}\n' \
    "$(hostname)" "$1" "$LABEL" "$2" "$3" "$5" "$LOAD_BEFORE" "$l" "$4" "$SHA" "$JOBS" "$(date -u +%FT%TZ)" | tee -a "$RESULTS"
}
timeit() { local tool=$1 scen=$2 cache=$3; shift 3
  LOAD_BEFORE=$(cut -d' ' -f1-3 /proc/loadavg); local t0 t1 rc=0
  t0=$(date +%s.%N); "$@" >"$PILOT/logs/$tool-$scen.log" 2>&1 || rc=$?; t1=$(date +%s.%N)
  record "$tool" "$scen" "$(printf %.3f "$(echo "$t1 - $t0" | bc)")" "$cache" "$rc"; }
clear_zig() { rm -rf "$SRC/ghostty-next/.zig-cache" "$SRC/ghostty-next/zig-pkg" "$ZIG_GLOBAL_CACHE_DIR"; mkdir -p "$ZIG_GLOBAL_CACHE_DIR"; }
# A second worktree has no local .zig-cache/zig-pkg but a warm global zig cache.
clear_zig_local() { rm -rf "$SRC/ghostty-next/.zig-cache" "$SRC/ghostty-next/zig-pkg"; }
bz() { "$PILOT/bz" "$@"; }
rmob() { [[ -d $1 ]] && chmod -R u+w "$1"; rm -rf "$1"; }
BZ=(--repository_cache="$PILOT/repo-cache" --jobs="$JOBS")

# bazel-remote on loopback, as a stand-in for a shared team cache server.
if ! curl -fsS http://127.0.0.1:9092/status >/dev/null 2>&1; then
  rm -rf "$PILOT/remote-cache"
  nohup "$PILOT/bin/bazel-remote" --dir "$PILOT/remote-cache" --max_size 100 \
    --http_address 127.0.0.1:9092 --grpc_address 127.0.0.1:9093 >"$PILOT/logs/bazel-remote.log" 2>&1 &
  for _ in $(seq 50); do curl -fsS http://127.0.0.1:9092/status >/dev/null 2>&1 && break; sleep 0.2; done
fi
RC=(--remote_cache=grpc://127.0.0.1:9093)

for ob in ob-rcA ob-rcB; do bz $ob shutdown >/dev/null 2>&1 || true; rmob "$PILOT/$ob"; done
clear_zig
timeit bazel remote_cache_populate "empty output base A, empty remote cache (uploads)" bz ob-rcA build "${BZ[@]}" "${RC[@]}" $LABEL
bz ob-rcA shutdown >/dev/null 2>&1 || true
clear_zig_local
timeit bazel remote_cache_hit "empty output base B, warm remote cache, no disk cache" bz ob-rcB build "${BZ[@]}" "${RC[@]}" $LABEL
grep -E "processes:" "$PILOT/logs/bazel-remote_cache_hit.log" | tail -1 || true
bz ob-rcB shutdown >/dev/null 2>&1 || true

# cargo analogue of a shared cache: sccache (local dir). Incremental must be
# off for sccache to cache workspace crates; build scripts and links rerun.
if command -v sccache >/dev/null; then
  export SCCACHE_SERVER_PORT=4299 SCCACHE_DIR=$PILOT/sccache SCCACHE_CACHE_SIZE=50G RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0
  sccache --stop-server >/dev/null 2>&1 || true; rm -rf "$SCCACHE_DIR"
  export CARGO_TARGET_DIR=$PILOT/cargo-target-sc
  rm -rf "$CARGO_TARGET_DIR"; clear_zig
  cd "$SRC/cmux-tui"
  timeit cargo sccache_populate "empty target, empty sccache, incremental off" cargo build --locked -j "$JOBS" -p "$PKG"
  rm -rf "$CARGO_TARGET_DIR"; clear_zig_local
  timeit cargo sccache_hit "empty target, warm sccache, incremental off" cargo build --locked -j "$JOBS" -p "$PKG"
  sccache --show-stats | tee "$PILOT/logs/sccache-stats.txt" | grep -E "Cache hits|Cache misses|Non-cacheable" || true
  sccache --stop-server >/dev/null 2>&1 || true
fi
