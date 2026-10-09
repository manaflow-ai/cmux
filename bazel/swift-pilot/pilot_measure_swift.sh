#!/usr/bin/env bash
# Bazel pilot Swift slice: time rules_swift and `swift build` on one Mac.
# Usage: pilot_measure_swift.sh [bazel|swiftpm|both]
set -euo pipefail
P=/Volumes/ephemeral0/bazel-pilot
SRC=$P/src
WHICH="${1:-both}"
SHA="${PILOT_SHA:-89b472d502a1ec9936a978ba7ee7479b7d21cfd6}"
RESULTS=$P/results.jsonl
LEAF="Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/AgentQuestionFixture.swift"
TOP="Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Contact/ContactAddress.swift"
mkdir -p $P/logs
load() { sysctl -n vm.loadavg | tr -d '{}' | xargs; }
timeit() { local tool=$1 scen=$2 cache=$3; shift 3; local lb; lb=$(load); local rc=0
  local t0 t1; t0=$(python3 -c 'import time;print(time.time())')
  "$@" >"$P/logs/$tool-$scen.log" 2>&1 || rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  printf '{"host":"%s","tool":"%s","scenario":"%s","seconds":%.2f,"exit":%s,"load_before":"%s","load_after":"%s","cache":"%s","sha":"%s","at":"%s"}\n' \
    "$(hostname -s)" "$tool" "$scen" "$(python3 -c "print($t1-$t0)")" "$rc" "$lb" "$(load)" "$cache" "$SHA" "$(date -u +%FT%TZ)" | tee -a "$RESULTS"; }
edit() { printf '\npublic let bazelPilotEdit%s = %s\n' "$2" "$RANDOM" >> "$SRC/$1"; }
revert() { python3 - "$SRC/$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"\npublic let bazelPilotEdit[A-Za-z]+ = \d+\n", "", s))
PY
}
rmob() { [[ -d $1 ]] && chmod -R u+w "$1"; rm -rf "$1"; }
bz() { (cd $SRC && $P/bin/bazelisk --output_user_root=$P/root --output_base=$P/ob-measure "$@"); }
TARGETS=(//Packages/Shared/CmuxHomeCore:CmuxHomeCore)
if [[ $WHICH == bazel || $WHICH == both ]]; then
  bz shutdown >/dev/null 2>&1 || true; rmob $P/ob-measure; rm -rf $P/disk-measure
  timeit bazel cold "empty output base and disk cache, repo cache warm" bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}"
  timeit bazel noop "warm" bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}"
  edit "$LEAF" Leaf; timeit bazel leaf_edit "warm" bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}"; revert "$LEAF"
  bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}" >/dev/null 2>&1
  edit "$TOP" Top; timeit bazel top_edit "warm" bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}"; revert "$TOP"
  bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}" >/dev/null 2>&1
  bz shutdown >/dev/null 2>&1 || true
fi
if [[ $WHICH == swiftpm || $WHICH == both ]]; then
  cd $SRC/Packages/Shared/CmuxHomeCore
  rm -rf .build
  timeit swiftpm cold "empty .build (resolve has no remote deps)" swift build --target CmuxHomeCore
  timeit swiftpm noop "warm .build" swift build --target CmuxHomeCore
  edit "$LEAF" Leaf; timeit swiftpm leaf_edit "warm .build" swift build --target CmuxHomeCore; revert "$LEAF"
  swift build --target CmuxHomeCore >/dev/null 2>&1
  edit "$TOP" Top; timeit swiftpm top_edit "warm .build" swift build --target CmuxHomeCore; revert "$TOP"
  swift build --target CmuxHomeCore >/dev/null 2>&1
fi
if [[ $WHICH == extra ]]; then
  # Server already running: isolates Bazel startup from compile work.
  bz build --repository_cache=$P/repo-cache "${TARGETS[@]}" >/dev/null 2>&1
  bz clean >/dev/null 2>&1
  timeit bazel cold_server_running "bazel clean, server up, no disk cache" bz build --repository_cache=$P/repo-cache "${TARGETS[@]}"
  bz shutdown >/dev/null 2>&1 || true
  # A second checkout / agent: new output base, shared warm disk cache.
  rmob $P/ob-measure
  timeit bazel fresh_ob_disk_cache_hit "new output base, warm disk cache" bz build --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure "${TARGETS[@]}"
  bz shutdown >/dev/null 2>&1 || true
  # Tests: Bazel caches passing results; swift test always reruns.
  timeit bazel test_cold "test both packages, warm disk cache" bz test --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure //Packages/...
  timeit bazel test_cached "rerun, nothing changed" bz test --repository_cache=$P/repo-cache --disk_cache=$P/disk-measure //Packages/...
  bz shutdown >/dev/null 2>&1 || true
  (cd $SRC/Packages/Shared/CmuxHomeCore && swift build --build-tests >/dev/null 2>&1)
  timeit swiftpm test_rerun "warm .build, swift test CmuxHomeCore" bash -c "cd $SRC/Packages/Shared/CmuxHomeCore && swift test"
fi
