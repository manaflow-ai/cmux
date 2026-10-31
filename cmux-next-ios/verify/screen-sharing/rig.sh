#!/usr/bin/env bash
# Screen Sharing live rig (verify/screen-sharing.md): the Debug app on a fleet
# Mac's simulator (the viewer) controls a real Mac (the host: a tagged cmux NEXT
# build sharing its screen, with InputProbe in front) through the device hub.
# Never builds on this laptop and never opens Simulator.app here.
#
#   rig.sh sync            xcodegen here, rsync the sources to $HOST:$DIR
#   rig.sh seed-xcf        copy the Rust xcframework into $DIR from FROM=host:dir (default aws-m4pro-6:smooth-lists)
#   rig.sh sim             create + boot $SIM_NAME (iPhone 17 Pro, iOS 26.5) on $HOST
#   rig.sh build           build-for-testing, Debug (the dev hub, password sign-in)
#   rig.sh test LABEL      run ScreenSharingLiveUITests with a screen recording; copies LABEL.mp4 and
#                          the step screenshots to verify/evidence/screen-sharing/LABEL/.
#                          Needs CREDS (a 0600 file with CMUX_UITEST_STACK_EMAIL/PASSWORD; copied for
#                          the run and deleted after) and MAC (the host's device name).
#                          xcodebuild sometimes never exits after the test ends on the fleet hosts; the
#                          rig ends it 30 s after "Executed 1 test" so the result bundle and video are written.
#
# Environment: HOST (default aws-m4pro-6), DIR (default screen-sharing), SIM_NAME (default cmux-ss-1).
set -euo pipefail
HOST=${HOST:-aws-m4pro-6}
DIR=${DIR:-screen-sharing}
SIM_NAME=${SIM_NAME:-cmux-ss-1}
here=$(cd "$(dirname "$0")" && pwd)
mobile=$(cd "$here/../.." && pwd)
repo=$(cd "$mobile/.." && pwd)
ts=${TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
if [[ $HOST == mini-* ]]; then dest=$HOST; rsh=ssh; else dest=ec2-user@$HOST; rsh="$ts ssh"; fi
remote() { $rsh "$dest" "$@"; }
remote_env='export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer;'
products=build/ss

case "${1:-}" in
  sync)
    (cd "$mobile" && xcodegen generate -q)
    rsync -a --delete -e "$rsh" --exclude .build --exclude build --exclude 'verify/' --exclude 'CmuxMobileKit/Frameworks/' \
      --exclude 'rust/target' "$mobile" "$dest:$DIR/"
    rsync -a --delete -e "$rsh" --exclude .build "$repo/Packages" "$dest:$DIR/"
    remote "mkdir -p $DIR/vendor $DIR/cmux-tui"
    rsync -a -e "$rsh" "$repo/vendor/stack-auth-swift-sdk-prerelease" "$dest:$DIR/vendor/"
    rsync -a -e "$rsh" "$repo/AppIcon.icon" "$dest:$DIR/"
    rsync -a --delete -e "$rsh" "$repo/schemas" "$dest:$DIR/"
    rsync -a --delete -e "$rsh" "$repo/cmux-tui/spec" "$dest:$DIR/cmux-tui/"
    remote "touch $DIR/.synced"
    ;;
  seed-xcf)
    from=${FROM:-aws-m4pro-6:smooth-lists}
    fhost=${from%%:*} fdir=${from#*:}
    if [[ $fhost == mini-* ]]; then fsh=(ssh "$fhost"); else fsh=("$ts" ssh "ec2-user@$fhost"); fi
    "${fsh[@]}" "cd $fdir/cmux-next-ios/CmuxMobileKit && tar cf - Frameworks/CmuxMobileLinkFFI.xcframework" \
      | remote "mkdir -p $DIR/cmux-next-ios/CmuxMobileKit && cd $DIR/cmux-next-ios/CmuxMobileKit && tar xf -"
    ;;
  sim)
    remote "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      if [[ -z \$udid ]]; then udid=\$(xcrun simctl create '$SIM_NAME' '${DEVICE:-iPhone 17 Pro}' com.apple.CoreSimulator.SimRuntime.iOS-26-5); fi; \
      xcrun simctl boot \$udid 2>/dev/null; xcrun simctl bootstatus \$udid -b >/dev/null; echo \$udid"
    ;;
  build)
    remote "$remote_env cd $DIR/cmux-next-ios && xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath $products -jobs 6 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build-for-testing > build-ss.log 2>&1; rc=\$?; \
      grep -E 'error:|BUILD (SUCCEEDED|FAILED)|TEST BUILD (SUCCEEDED|FAILED)' build-ss.log | sort -u | head -30; exit \$rc"
    ;;
  test)
    label=${2:?label}
    : "${CREDS:?CREDS=<0600 file with CMUX_UITEST_STACK_EMAIL/PASSWORD>}" "${MAC:?MAC=<host device name>}"
    out="$mobile/verify/evidence/screen-sharing/$label"; mkdir -p "$out"
    secret=".ss-creds-$$"
    $rsh "$dest" "umask 077; cat > $secret" < "$CREDS"
    remote "$remote_env set -u; cd $DIR/cmux-next-ios; . ~/$secret; rm -f ~/$secret; \
      udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      rm -rf ss-$label.xcresult ss-$label.mp4; \
      xcrun simctl io \$udid recordVideo --codec=h264 --force ss-$label.mp4 > rec.log 2>&1 & rec=\$!; \
      TEST_RUNNER_CMUX_SS_LIVE=1 TEST_RUNNER_CMUX_SS_MAC='$MAC' TEST_RUNNER_CMUX_SS_EMAIL=\"\$CMUX_UITEST_STACK_EMAIL\" \
      TEST_RUNNER_CMUX_SS_PASSWORD=\"\$CMUX_UITEST_STACK_PASSWORD\" ${HUB:+TEST_RUNNER_CMUX_SS_HUB=$HUB} \
      xcodebuild test-without-building -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
        -destination id=\$udid -derivedDataPath $products -resultBundlePath ss-$label.xcresult \
        -only-testing:CmuxMobileAppUITests/ScreenSharingLiveUITests > test-$label.log 2>&1 & xb=\$!; \
      ( until grep -q 'Executed 1 test' test-$label.log 2>/dev/null; do sleep 2; done; sleep 30; kill -INT \$xb 2>/dev/null ) & watch=\$!; \
      wait \$xb; rc=\$?; kill \$watch 2>/dev/null; \
      kill -INT \$rec; wait \$rec 2>/dev/null; \
      rm -rf att-$label; mkdir att-$label; xcrun xcresulttool export attachments --path ss-$label.xcresult --output-path att-$label >/dev/null 2>&1; \
      grep -E 'Test Case|error|passed|failed|skipped' test-$label.log | tail -20; exit \$rc" || rc=$?
    rsync -a -e "$rsh" "$dest:$DIR/cmux-next-ios/ss-$label.mp4" "$dest:$DIR/cmux-next-ios/att-$label" "$dest:$DIR/cmux-next-ios/test-$label.log" "$out/" || true
    exit "${rc:-0}"
    ;;
  *)
    sed -n 2,16p "$0"; exit 2 ;;
esac
