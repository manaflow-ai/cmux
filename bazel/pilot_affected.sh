#!/usr/bin/env bash
# Bazel pilot: affected-test selection. Compares `bazel query rdeps` and
# cached `bazel test` against what cargo reruns for the same crates.
# Usage: bazel/pilot_affected.sh CRATE_DIR...   (first-party crates to test)
set -uo pipefail
PILOT=/work/bazel-pilot
SRC=$PILOT/src
SHA="${PILOT_SHA:-89b472d502a1ec9936a978ba7ee7479b7d21cfd6}"
JOBS="${JOBS:-64}"
RESULTS=$PILOT/results.jsonl
OUT=$PILOT/logs/affected.txt
LABEL=affected
export RUSTUP_HOME=/work/rust/rustup CARGO_HOME=$PILOT/cargo-home
export PATH=/work/rust/cargo/bin:/usr/local/bin:/usr/bin:/bin
export ZIG_GLOBAL_CACHE_DIR=$PILOT/zig-global
export CARGO_TARGET_DIR=$PILOT/cargo-target
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
bz() { "$PILOT/bz" ob-affected "$@"; }
edit() { printf '\npub const BAZEL_PILOT_EDIT_%s: u32 = %s;\n' "$2" "$RANDOM" >> "$SRC/$1"; }
revert() { python3 - "$SRC/$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\npub const BAZEL_PILOT_EDIT_[A-Z_]+: u32 = \d+;\n", "", s))
PY
}
BZ=(--repository_cache="$PILOT/repo-cache" --disk_cache="$PILOT/disk-affected" --jobs="$JOBS")
: > "$OUT"
cd "$SRC"
total=$(bz query 'tests(//cmux-tui/...)' 2>/dev/null | wc -l)
echo "total rust_test targets in the slice: $total" | tee -a "$OUT"
for lib in //cmux-tui/crates/cmux-terminal-sizing:cmux_terminal_sizing //cmux-tui/crates/ghostty-vt:ghostty_vt //cmux-tui/crates/cmux-tui-core:cmux_tui_core; do
  n=$(bz query "kind(rust_test, rdeps(//cmux-tui/..., $lib))" 2>/dev/null | wc -l)
  pk=$(bz query "kind(rust_test, rdeps(//cmux-tui/..., $lib))" 2>/dev/null | sed 's#:.*##' | sort -u | wc -l)
  echo "edit $lib -> $n of $total test targets in $pk packages" | tee -a "$OUT"
done

# Bazel: run every test once (fills the test-result cache), then edit a leaf
# crate and rerun the whole pattern; only affected tests execute.
timeit bazel test_all_first "first run, build outputs warm in disk cache" bz test "${BZ[@]}" --keep_going //cmux-tui/...
grep -E "Executed|tests pass|fail" "$PILOT/logs/bazel-test_all_first.log" | tail -3 | tee -a "$OUT"
timeit bazel test_all_cached "nothing changed" bz test "${BZ[@]}" --keep_going //cmux-tui/...
grep -E "Executed" "$PILOT/logs/bazel-test_all_cached.log" | tail -1 | tee -a "$OUT"
edit cmux-tui/crates/cmux-terminal-sizing/src/lib.rs LEAF
timeit bazel test_after_leaf_edit "leaf crate edited; cached results for the rest" bz test "${BZ[@]}" --keep_going //cmux-tui/...
grep -E "Executed" "$PILOT/logs/bazel-test_after_leaf_edit.log" | tail -1 | tee -a "$OUT"
revert cmux-tui/crates/cmux-terminal-sizing/src/lib.rs
bz shutdown >/dev/null 2>&1

# cargo has no test-result cache: any edit reruns every selected test binary.
cd "$SRC/cmux-tui"
pkgs=()
for d in "$@"; do pkgs+=(-p "$(python3 -c "import tomllib,sys;print(tomllib.load(open('$SRC/$d/Cargo.toml','rb'))['package']['name'])")"); done
cargo test --locked -j "$JOBS" --no-run "${pkgs[@]}" >/dev/null 2>&1
timeit cargo test_all "warm target; cargo reruns every test of the selected crates" cargo test --locked -j "$JOBS" "${pkgs[@]}" --no-fail-fast
grep -E "^test result:" "$PILOT/logs/cargo-test_all.log" | awk '{p+=$4; f+=$6} END {print "cargo test: passed", p, "failed", f}' | tee -a "$OUT"
edit cmux-tui/crates/cmux-terminal-sizing/src/lib.rs LEAF
timeit cargo test_after_leaf_edit "leaf crate edited; cargo rebuilds dependents and reruns all selected tests" cargo test --locked -j "$JOBS" "${pkgs[@]}" --no-fail-fast
revert cmux-tui/crates/cmux-terminal-sizing/src/lib.rs
