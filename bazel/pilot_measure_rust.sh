#!/usr/bin/env bash
# Bazel pilot: time Bazel and cargo on the same host, SHA and target.
# Usage: bazel/pilot_measure_rust.sh LABEL CARGO_PKG [bazel|cargo|both]
#   LABEL      Bazel target, e.g. //cmux-tui/crates/cmux-tui-core:cmux_tui_core
#   CARGO_PKG  cargo package for `cargo build -p`, e.g. cmux-tui-core
# Every result is one JSON line in $PILOT/results.jsonl with host, load
# average, cache state and SHA. Edits are reverted after each scenario.
set -euo pipefail
PILOT=/work/bazel-pilot
SRC=$PILOT/src
LABEL="$1"; PKG="$2"; WHICH="${3:-both}"
SHA="${PILOT_SHA:-89b472d502a1ec9936a978ba7ee7479b7d21cfd6}"
LEAF_FILE="${LEAF_FILE:-cmux-tui/crates/cmux-terminal-sizing/src/lib.rs}"
CORE_FILE="${CORE_FILE:-cmux-tui/crates/cmux-tui-core/src/lib.rs}"
JOBS="${JOBS:-64}"
RESULTS=$PILOT/results.jsonl
export RUSTUP_HOME=/work/rust/rustup CARGO_HOME=$PILOT/cargo-home
export PATH=/work/rust/cargo/bin:/usr/local/bin:/usr/bin:/bin
export ZIG_GLOBAL_CACHE_DIR=$PILOT/zig-global
export CARGO_TARGET_DIR=$PILOT/cargo-target
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang
export RUSTFLAGS="-C link-arg=-fuse-ld=mold"
export CMUX_TUI_BUILD_COMMIT="$SHA" CMUX_GIT_SHORT_SHA="${SHA:0:9}"

record() { # tool scenario seconds cache_state exit
  local l; l=$(cut -d' ' -f1-3 /proc/loadavg)
  printf '{"host":"%s","tool":"%s","target":"%s","scenario":"%s","seconds":%s,"exit":%s,"load_before":"%s","load_after":"%s","cache":"%s","sha":"%s","jobs":%s,"at":"%s"}\n' \
    "$(hostname)" "$1" "$LABEL" "$2" "$3" "$5" "$LOAD_BEFORE" "$l" "$4" "$SHA" "$JOBS" "$(date -u +%FT%TZ)" | tee -a "$RESULTS"
}
timeit() { # tool scenario cache_state cmd...
  local tool=$1 scen=$2 cache=$3; shift 3
  LOAD_BEFORE=$(cut -d' ' -f1-3 /proc/loadavg)
  local t0 t1 rc=0
  t0=$(date +%s.%N)
  "$@" >"$PILOT/logs/$tool-$scen.log" 2>&1 || rc=$?
  t1=$(date +%s.%N)
  record "$tool" "$scen" "$(printf %.3f "$(echo "$t1 - $t0" | bc)")" "$cache" "$rc"
}
clear_zig() { rm -rf "$SRC/ghostty-next/.zig-cache" "$SRC/ghostty-next/zig-pkg" "$ZIG_GLOBAL_CACHE_DIR"; mkdir -p "$ZIG_GLOBAL_CACHE_DIR"; }
edit() { printf '\npub const BAZEL_PILOT_EDIT_%s: u32 = %s;\n' "$2" "$RANDOM" >> "$SRC/$1"; }
revert() { python3 - "$SRC/$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\npub const BAZEL_PILOT_EDIT_[A-Z_]+: u32 = \d+;\n", "", s))
PY
}

bz() { "$PILOT/bz" "$@"; }
rmob() { [[ -d $1 ]] && chmod -R u+w "$1"; rm -rf "$1"; }  # Bazel outputs are read-only
BZ_FLAGS=(--repository_cache="$PILOT/repo-cache" --jobs="$JOBS")

if [[ "$WHICH" == bazel || "$WHICH" == both ]]; then
  OB=ob-measure
  bz $OB shutdown >/dev/null 2>&1 || true
  rmob "$PILOT/$OB"; rm -rf "$PILOT/disk-measure"; clear_zig
  timeit bazel cold "empty output base, empty disk cache, repo cache warm (downloads only)" \
    bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL
  timeit bazel noop "warm output base" bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL
  edit "$LEAF_FILE" LEAF
  timeit bazel leaf_edit "warm output base" bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL
  revert "$LEAF_FILE"
  bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL >/dev/null 2>&1
  edit "$CORE_FILE" CORE
  timeit bazel core_edit "warm output base" bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL
  revert "$CORE_FILE"
  bz $OB build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL >/dev/null 2>&1
  # Same disk cache, brand-new output base: what a second worktree/agent sees.
  bz ob-measure2 shutdown >/dev/null 2>&1 || true; rmob "$PILOT/ob-measure2"
  timeit bazel fresh_ob_disk_cache_hit "empty output base, warm local disk cache" \
    bz ob-measure2 build "${BZ_FLAGS[@]}" --disk_cache="$PILOT/disk-measure" $LABEL
  bz ob-measure2 shutdown >/dev/null 2>&1 || true
fi

if [[ "$WHICH" == cargo || "$WHICH" == both ]]; then
  rm -rf "$CARGO_TARGET_DIR"; clear_zig
  cd "$SRC/cmux-tui"
  timeit cargo cold "empty target dir, registry warm (downloads only)" cargo build --locked -j "$JOBS" -p "$PKG"
  timeit cargo noop "warm target dir" cargo build --locked -j "$JOBS" -p "$PKG"
  edit "$LEAF_FILE" LEAF
  timeit cargo leaf_edit "warm target dir, incremental on" cargo build --locked -j "$JOBS" -p "$PKG"
  revert "$LEAF_FILE"
  cargo build --locked -j "$JOBS" -p "$PKG" >/dev/null 2>&1
  edit "$CORE_FILE" CORE
  timeit cargo core_edit "warm target dir, incremental on" cargo build --locked -j "$JOBS" -p "$PKG"
  revert "$CORE_FILE"
  cargo build --locked -j "$JOBS" -p "$PKG" >/dev/null 2>&1
fi
