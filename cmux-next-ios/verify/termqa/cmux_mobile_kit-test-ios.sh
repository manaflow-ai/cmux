#!/bin/zsh
# cmux_mobile_kit-test-ios.sh TESTS: runs CmuxMobileKit tests for TESTS (xcodebuild
# -only-testing, e.g. CmuxMobileLiveTests/MultiMacLinkTests) in an iOS simulator on
# mini-cmux11s (never on the laptop). The coordinator tests are `#if os(iOS)`, so
# `cmux_mobile_kit-test.sh` (`swift test` on macOS) skips them.
#
# Syncs this checkout's Packages, vendor, cmux-next-ios and cmux-tui (the link crate
# depends on cmux-tui crates) into ~/$dir/src on the mini.
# The FFI xcframework is not committed: the first run builds it there
# (rust/scripts/build-xcframework.sh); later runs reuse it. The simulator is this
# script's own (`kit-$dir`), shut down at the end. Code coverage is off: its counters
# crash the Xcode 26.6 frontend on CmuxMobileTerminal (emitIsolatingDestructor).
set -euo pipefail
here=${0:a:h}
repo=${here:h:h:h}
host=${CMUX_MOBILE_KIT_TEST_HOST:-mini-cmux11s-mac-mini}
dir=${CMUX_MOBILE_KIT_TEST_DIR:-kit-ios-test}  # one per concurrent agent
tests=${1:?usage: cmux_mobile_kit-test-ios.sh CmuxMobileLiveTests[/Suite[/test]] [more...]}
ssh $host "mkdir -p ~/${dir}/src ~/${dir}/logs"
rsync -a --delete --exclude '.build' --exclude 'build/' --exclude 'target/' --exclude 'Frameworks/' \
  --exclude 'cmux-next-ios/verify/' --exclude 'cmux-next-ios/design/' \
  --exclude 'cmux-tui/frontends/' --exclude 'node_modules/' \
  $repo/Packages $repo/vendor $repo/cmux-next-ios $repo/cmux-tui ${host}:${dir}/src/
only=$(for t in "$@"; do print -n " -only-testing:$t"; done)
ssh $host "zsh -l" <<EOF
set -euo pipefail
export DEVELOPER_DIR=\$(ls -d /Applications/Xcode_26.6.app /Applications/Xcode.app 2>/dev/null | head -1)/Contents/Developer
export PATH=/opt/homebrew/bin:\$HOME/.cargo/bin:\$PATH
src=~/${dir}/src/cmux-next-ios
if [[ ! -d \$src/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework ]]; then
  (cd \$src/rust && JOBS=6 bash scripts/build-xcframework.sh > ~/${dir}/logs/xcframework.log 2>&1) || { tail -20 ~/${dir}/logs/xcframework.log; exit 1; }
fi
name=kit-${dir}
udid=\$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for v in d.values() for x in v if x['name']=='\$name'), ''))")
if [[ -z \$udid ]]; then
  runtime=\$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['isAvailable'] and x['platform']=='iOS']; print(r[-1]['identifier'])")
  udid=\$(xcrun simctl create \$name "iPhone 17" \$runtime)
fi
cd \$src/CmuxMobileKit
rc=0
xcodebuild test -scheme CmuxMobileKit-Package -destination "id=\$udid" -derivedDataPath ~/${dir}/dd \
  -enableCodeCoverage NO CODE_SIGNING_ALLOWED=NO ${only} > ~/${dir}/logs/test.log 2>&1 || rc=\$?
xcrun simctl shutdown \$udid >/dev/null 2>&1 || true
grep -E "error:|✘|failed|passed after|Test run with|issue|TEST (SUCCEEDED|FAILED)" ~/${dir}/logs/test.log | tail -60 || true
exit \$rc
EOF
