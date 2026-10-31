#!/usr/bin/env bash
# Feed scroll-performance rig: builds the Demo app for the simulator on a cmux
# Mac mini and runs the Feed stress with the in-app frame-interval log (G-04).
# Never builds on this laptop and never opens Simulator.app.
#
#   rig.sh sync              xcodegen here, rsync sources + CmuxMobileLinkFFI.xcframework to $HOST:$DIR
#   rig.sh build             Demo simulator build on the mini (arm64 only)
#   rig.sh ship              copy the built app from $HOST to $RUN_HOST (a quieter mini for timing)
#   rig.sh sim               create + boot the rig's own simulator ($SIM_NAME, a $SIM_DEVICE) on $RUN_HOST
#   rig.sh run LABEL [K=V..] install, launch on the Feed with CMUX_MOBILE_FRAMELOG=1 and the
#                            given CMUX_MOBILE_* settings, wait for the app to exit after the autoscroll,
#                            copy framelog.jsonl to verify/evidence/feedperf/LABEL.jsonl
#   rig.sh trace LABEL TEMPLATE [K=V..]
#                            as run, with `xctrace record --template TEMPLATE --attach` on the app for
#                            the whole run; the trace lands in verify/evidence/feedperf/LABEL.trace.
#                            TEMPLATE=sample runs `sample` for SECS (default 60) at 1 ms instead (set SECS past
#                            the app's exit, -mayDie ends it with the app's frame log written): xctrace
#                            does not record over SSH on the minis (Developer Mode is off, it waits for an
#                            authorization prompt) and `sample` needs none.
#
# Environment: HOST (build mini, default mini-cmux11s-mac-mini), RUN_HOST (simulator mini,
# default HOST), DIR (default feedperf), SIM_NAME (default cmux-mobile-feedperf-1),
# SIM_DEVICE (default iPhone 17 Pro), XCF (CmuxMobileLinkFFI.xcframework to ship).
set -euo pipefail
HOST=${HOST:-mini-cmux11s-mac-mini}
DIR=${DIR:-feedperf}
SIM_NAME=${SIM_NAME:-cmux-mobile-feedperf-1}
SIM_DEVICE=${SIM_DEVICE:-iPhone 17 Pro}
RUN_HOST=${RUN_HOST:-$HOST}
here=$(cd "$(dirname "$0")" && pwd)
mobile=$(cd "$here/../.." && pwd)
repo=$(cd "$mobile/.." && pwd)
# RUN_HOST=ts:NAME reaches NAME with Tailscale SSH (the AWS Macs: ec2-user@aws-m4pro-N, which have
# Developer Mode on, so xctrace can attach; the cmux minis have it off and xctrace waits for an
# authorization nobody can give over SSH).
run_ssh() {
  if [[ $RUN_HOST == ts:* ]]; then
    "${TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}" ssh "${RUN_HOST#ts:}" "$@"
  else
    ssh "$RUN_HOST" "$@"
  fi
}
remote_env='export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer;'

case "${1:-}" in
  sync)
    (cd "$mobile" && xcodegen generate -q)
    ssh "$HOST" "mkdir -p $DIR"
    rsync -a --delete --exclude .build --exclude build --exclude 'verify/' --exclude 'CmuxMobileKit/Frameworks/' \
      "$mobile" "$HOST:$DIR/"
    rsync -a --delete --exclude .build "$repo/Packages" "$HOST:$DIR/"
    ssh "$HOST" "mkdir -p $DIR/vendor"
    rsync -a "$repo/vendor/stack-auth-swift-sdk-prerelease" "$HOST:$DIR/vendor/"
    rsync -a "$repo/AppIcon.icon" "$HOST:$DIR/"
    xcf=${XCF:-$(ls -td "$HOME"/cmux-mobile-builds/.cache/xcframework/*/CmuxMobileLinkFFI.xcframework | head -1)}
    key=$(printf '%s\n' "$(git -C "$repo" rev-parse 'HEAD:cmux-next-ios/rust')" "$(git -C "$repo" rev-parse 'HEAD:cmux-tui/crates/cmux-wg')" \
      "$(git -C "$repo" rev-parse 'HEAD:cmux-tui/crates/cmux-transport')" | shasum | cut -c1-16)
    [[ -d "$HOME/cmux-mobile-builds/.cache/xcframework/$key" && -z "${XCF:-}" ]] && xcf="$HOME/cmux-mobile-builds/.cache/xcframework/$key/CmuxMobileLinkFFI.xcframework"
    echo "xcframework: $xcf (want key $key)"
    ssh "$HOST" "mkdir -p $DIR/cmux-next-ios/CmuxMobileKit/Frameworks"
    rsync -a --delete "$xcf" "$HOST:$DIR/cmux-next-ios/CmuxMobileKit/Frameworks/"
    # rsync keeps mtimes; touch so SwiftPM never reuses an older build of a changed file.
    ssh "$HOST" "find $DIR/cmux-next-ios/CmuxMobileKit/Sources -name '*.swift' -newer $DIR/.synced -exec touch {} + 2>/dev/null; touch $DIR/.synced"
    ;;
  build)
    ssh "$HOST" "$remote_env cd $DIR/cmux-next-ios && xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath build/demo -jobs 8 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CMUX_MOBILE_TAG=.feedperf 'CMUX_MOBILE_DISPLAY_NAME=mobile feedperf' \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) DEBUG CMUX_MOBILE_DEMO' build > build-demo.log 2>&1; rc=\$?; \
      grep -E 'error:|BUILD (SUCCEEDED|FAILED)' build-demo.log | sort -u | head -30; exit \$rc"
    ;;
  ship)
    [[ "$RUN_HOST" == "$HOST" ]] && exit 0
    run_ssh "mkdir -p $DIR/cmux-next-ios/build/demo/Build/Products"
    ssh "$HOST" "cd $DIR/cmux-next-ios/build/demo/Build/Products && tar cf - Demo-iphonesimulator/*.app" \
      | run_ssh "cd $DIR/cmux-next-ios/build/demo/Build/Products && rm -rf Demo-iphonesimulator && tar xf -"
    ;;
  sim)
    run_ssh "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      if [[ -z \$udid ]]; then udid=\$(xcrun simctl create '$SIM_NAME' '$SIM_DEVICE' com.apple.CoreSimulator.SimRuntime.iOS-26-5); fi; \
      xcrun simctl boot \$udid 2>/dev/null; xcrun simctl bootstatus \$udid -b >/dev/null; echo \$udid"
    ;;
  run|trace)
    mode=$1 label=${2:?label}; shift 2
    template=""
    if [[ $mode == trace ]]; then template=${1:?template}; shift; fi
    envs="SIMCTL_CHILD_CMUX_MOBILE_FRAMELOG=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=${MOCK:-1}"
    for kv in "$@"; do envs+=" SIMCTL_CHILD_$kv"; done
    out="$mobile/verify/evidence/feedperf"; mkdir -p "$out"
    launch="SIMCTL_CHILD_CMUX_MOBILE_FEED_EXIT_WHEN_DONE=1 $envs perl -e 'alarm shift; exec @ARGV' ${WAIT:-300} \
        xcrun simctl launch --console-pty --terminate-running-process \$udid \$bid -cmux-mobile-tab feed -cmuxMobile.setupComplete YES -cmux-mobile-no-restore >/dev/null 2>&1"
    if [[ $mode == trace ]]; then
      # simctl launch without a console returns "<bundle>: <pid>" at once; xctrace attaches to that
      # pid and records until the app exits after its autoscroll.
      launch="rm -rf $DIR/$label.trace; pid=\$(SIMCTL_CHILD_CMUX_MOBILE_FEED_EXIT_WHEN_DONE=1 $envs xcrun simctl launch --terminate-running-process \$udid \$bid \
          -cmux-mobile-tab feed -cmuxMobile.setupComplete YES -cmux-mobile-no-restore | awk '{print \$NF}'); \
          if [[ '$template' == sample ]]; then sample \$pid ${SECS:-60} 1 -mayDie -file $DIR/$label.sample.txt >$DIR/$label.xctrace.log 2>&1; else \
          xcrun xctrace record --no-prompt --device \$udid --template '$template' --attach \$pid --time-limit ${WAIT:-300}s --output $DIR/$label.trace >$DIR/$label.xctrace.log 2>&1; fi"
    fi
    run_ssh "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      app=\$(ls -d $DIR/cmux-next-ios/build/demo/Build/Products/Demo-iphonesimulator/*.app | head -1); \
      bid=\$(plutil -extract CFBundleIdentifier raw \$app/Info.plist); \
      xcrun simctl terminate \$udid \$bid 2>/dev/null; xcrun simctl install \$udid \$app; \
      caches=\$(xcrun simctl get_app_container \$udid \$bid data)/Library/Caches; rm -f \$caches/framelog.jsonl; \
      $launch; \
      cat \$caches/framelog.jsonl" > "$out/$label.jsonl"
    if [[ $mode == trace ]]; then
      rm -rf "$out/$label.trace"
      if [[ $template == sample ]]; then
        run_ssh "cat $DIR/$label.sample.txt" > "$out/$label.sample.txt" && echo "sample: $out/$label.sample.txt"
      else
        run_ssh "cd $DIR && tar cf - $label.trace" | (cd "$out" && tar xf -) && echo "trace: $out/$label.trace"
      fi
    fi
    python3 "$here/summarize.py" "$out/$label.jsonl"
    ;;
  *) sed -n '2,23p' "$0"; exit 2 ;;
esac
