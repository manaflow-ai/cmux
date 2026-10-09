#!/usr/bin/env bash
# Bazel pilot: edit timings with the non-hermetic `--config=incr` hack
# (persistent rustc incremental dirs for first-party crates).
set -euo pipefail
PILOT=/work/bazel-pilot; SRC=$PILOT/src
LABEL="$1"; SHA="${PILOT_SHA:-89b472d502a1ec9936a978ba7ee7479b7d21cfd6}"; JOBS=64
RESULTS=$PILOT/results.jsonl
LEAF_FILE=cmux-tui/crates/cmux-terminal-sizing/src/lib.rs
CORE_FILE=cmux-tui/crates/cmux-tui-core/src/lib.rs
record() { local l; l=$(cut -d' ' -f1-3 /proc/loadavg)
  printf '{"host":"%s","tool":"%s","target":"%s","scenario":"%s","seconds":%s,"exit":%s,"load_before":"%s","load_after":"%s","cache":"%s","sha":"%s","jobs":%s,"at":"%s"}\n' \
    "$(hostname)" "$1" "$LABEL" "$2" "$3" "$5" "$LOAD_BEFORE" "$l" "$4" "$SHA" "$JOBS" "$(date -u +%FT%TZ)" | tee -a "$RESULTS"; }
timeit() { local tool=$1 scen=$2 cache=$3; shift 3
  LOAD_BEFORE=$(cut -d' ' -f1-3 /proc/loadavg); local t0 t1 rc=0
  t0=$(date +%s.%N); "$@" >"$PILOT/logs/$tool-$scen.log" 2>&1 || rc=$?; t1=$(date +%s.%N)
  record "$tool" "$scen" "$(printf %.3f "$(echo "$t1 - $t0" | bc)")" "$cache" "$rc"; }
edit() { printf '\npub const BAZEL_PILOT_EDIT_%s: u32 = %s;\n' "$2" "$RANDOM" >> "$SRC/$1"; }
revert() { python3 - "$SRC/$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\npub const BAZEL_PILOT_EDIT_[A-Z_]+: u32 = \d+;\n", "", s))
PY
}
bz() { "$PILOT/bz" ob-incr "$@"; }
BZ=(--config=incr --repository_cache="$PILOT/repo-cache" --jobs="$JOBS")
rm -rf "$PILOT/rustc-incr"
# Unsandboxed rustc cannot overwrite the read-only outputs a sandboxed build
# left behind, so the hack needs its own fresh output base.
bz shutdown >/dev/null 2>&1 || true
[[ -d $PILOT/ob-incr ]] && chmod -R u+w "$PILOT/ob-incr"; rm -rf "$PILOT/ob-incr"
# Prime: the incremental dirs only fill when rustc actually runs, so force one
# edit/revert cycle of each file before timing.
bz build "${BZ[@]}" $LABEL >"$PILOT/logs/incr-prime.log" 2>&1
for f in "$LEAF_FILE" "$CORE_FILE"; do edit "$f" PRIME; bz build "${BZ[@]}" $LABEL >>"$PILOT/logs/incr-prime.log" 2>&1; revert "$f"; done
bz build "${BZ[@]}" $LABEL >>"$PILOT/logs/incr-prime.log" 2>&1
edit "$LEAF_FILE" LEAF
timeit bazel_incr leaf_edit "warm output base + persistent rustc incremental dir (hack)" bz build "${BZ[@]}" $LABEL
revert "$LEAF_FILE"; bz build "${BZ[@]}" $LABEL >/dev/null 2>&1
edit "$CORE_FILE" CORE
timeit bazel_incr core_edit "warm output base + persistent rustc incremental dir (hack)" bz build "${BZ[@]}" $LABEL
revert "$CORE_FILE"; bz build "${BZ[@]}" $LABEL >/dev/null 2>&1
bz shutdown >/dev/null 2>&1 || true
