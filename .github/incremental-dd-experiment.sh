#!/usr/bin/env bash
# Experiment only (branch exp/incremental-dd-measure-20260923, never merged).
#
# Measures whether a DerivedData snapshot built at SEED lets a later build on a
# fresh checkout compile incrementally, through compile admission's exact
# canonical paths and build script. Every arm starts from a fresh copy of the
# repository (new inodes, every mtime = now) and a DerivedData extracted from
# the seed's tarball (new inodes), which is what a hosted runner sees.
#
#   cold  SEED, empty DerivedData
#   noop  SEED again, seed DerivedData      (floor: nothing changed)
#   edit  SEED + one private func in one app Swift file
#   mid   MID  (20 main commits after SEED), seed DerivedData
#   head  HEAD (40 main commits after SEED), seed DerivedData
set -uo pipefail

SEED="$1" MID="$2" HEAD_SHA="$3"
EDIT_FILE="Sources/Mobile/MobileAttachTicketStore.swift"
T="$RUNNER_TEMP"
ROOT=/private/tmp/cmux-ci
DD="$ROOT/derived-data-compile-admission"
CAS="$ROOT/compile-admission-cas"
WS="$T/ws"
MIRROR="$GITHUB_WORKSPACE"
TOOLS="$T/tools"
LOGS="$T/logs"
RESULTS="$T/results.tsv"
mkdir -p "$TOOLS" "$LOGS"
# One harness copy of the build scripts for every arm, so a script change
# between SEED and HEAD cannot masquerade as an incremental miss.
cp scripts/ci/compile-app-host-test-product.sh scripts/ci/canonical-build-root.sh \
  scripts/ci/capture-network-diagnostics.sh scripts/ci/e2e_warm_derived_data.py "$TOOLS"/
printf 'arm\tsha\tstatus\tresolve_s\tadopt_s\treplay_s\tbuild_s\tswiftcompile\tswiftcompile_cmux\temitmodule\tld\n' > "$RESULTS"

now() { python3 -c 'import time; print(time.monotonic())'; }
since() { python3 -c 'import sys; print(round(float(sys.argv[2])-float(sys.argv[1]), 1))' "$1" "$(now)"; }

prepare() {
  local sha="$1" edit="$2"
  rm -rf "$WS" "$ROOT/src" "$DD" "$CAS"
  cp -R "$MIRROR" "$WS"
  git -C "$WS" checkout -q -f --detach "$sha"
  git -C "$WS" submodule update -q --init --recursive --force
  git -C "$WS" clean -ffdxq -e GhosttyKit.xcframework -e .ci-source-packages
  if [ "$edit" = yes ]; then
    printf '\nprivate func cmuxIncrementalProbe() -> Int { 42 }\n' >> "$WS/$EDIT_FILE"
  fi
  if [ -d "$T/spm" ]; then
    rm -rf "$WS/.ci-source-packages"
    cp -R "$T/spm" "$WS/.ci-source-packages"
  fi
  stat -f 'probe %N mtime=%m inode=%i' "$WS/Sources/AppDelegate.swift"
}

arm() {
  local name="$1" sha="$2" edit="$3" warm="$4" t resolve_s adopt_s=0 replay_s=0 build_s status
  echo "::group::arm $name ($sha edit=$edit warm=$warm)"
  prepare "$sha" "$edit"
  cd "$WS"
  t=$(now)
  "$TOOLS/compile-app-host-test-product.sh" canonical-resolve "$DD" "$WS/.ci-source-packages"
  resolve_s=$(since "$t")
  if [ "$warm" = yes ]; then
    t=$(now)
    rm -rf "$DD"; mkdir -p "$DD"
    tar -xzf "$T/dd.tar.gz" -C "$DD"
    adopt_s=$(since "$t")
    t=$(now)
    python3 "$TOOLS/e2e_warm_derived_data.py" replay "$ROOT/src" "$T/manifest.json"
    replay_s=$(since "$t")
  else
    python3 "$TOOLS/e2e_warm_derived_data.py" record "$ROOT/src" "$T/manifest.json"
  fi
  t=$(now)
  "$TOOLS/compile-app-host-test-product.sh" canonical-build "$DD" "$WS/.ci-source-packages" "$CAS" "$LOGS/$name-build.log"
  status=$?
  build_s=$(since "$t")
  for scheme in cmux cmux-unit cmux-numeric-locale; do
    cp "$DD/$scheme-build.log" "$LOGS/$name-$scheme.log" 2>/dev/null || true
  done
  local log="$LOGS/$name-build.log"
  local sc scc em ld
  sc=$(grep -c '^SwiftCompile ' "$log" || true)
  scc=$(grep '^SwiftCompile ' "$log" | grep -c "(in target 'cmux' from project 'cmux')" || true)
  em=$(grep -c '^SwiftEmitModule ' "$log" || true)
  ld=$(grep -c '^Ld ' "$log" || true)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${sha:0:10}" "$status" "$resolve_s" "$adopt_s" "$replay_s" "$build_s" "$sc" "$scc" "$em" "$ld" | tee -a "$RESULTS"
  echo "::endgroup::"
  cd "$MIRROR"
  return "$status"
}

arm cold "$SEED" no no || { echo "cold build failed"; exit 1; }
rm -rf "$T/spm"; cp -R "$ROOT/src/.ci-source-packages" "$T/spm"
t=$(now)
tar -cf - -C "$DD" --exclude ./Logs --exclude ./Index.noindex . | gzip -1 > "$T/dd.tar.gz"
pack_s=$(since "$t")
echo "snapshot: $(stat -f %z "$T/dd.tar.gz") bytes gz, $(du -sk "$DD" | cut -f1) KiB raw, ${pack_s}s to pack" | tee "$T/snapshot.txt"

# A fresh checkout and a fresh extraction give every file a new inode.
defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

arm noop "$SEED" no yes
arm edit "$SEED" yes yes
arm mid "$MID" no yes
arm head "$HEAD_SHA" no yes

{
  echo "### Incremental DerivedData experiment"
  echo
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo
  cat "$T/snapshot.txt"
  echo
  echo '```'
  column -t -s $'\t' "$RESULTS"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
cat "$RESULTS"
