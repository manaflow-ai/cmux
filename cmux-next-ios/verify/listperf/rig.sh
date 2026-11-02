#!/usr/bin/env bash
# List scroll-performance rig: the Demo app on a fleet Mac's simulator, one list seeded
# and scrolled by ListStressRig (CmuxMobileShell/ListStressRig.swift) with the in-app
# frame-interval log (G-04). Never builds on this laptop and never opens Simulator.app.
#
#   rig.sh sync                xcodegen here, rsync sources to $HOST:$DIR (the Rust xcframework is built there once:
#                              `bash $DIR/cmux-next-ios/rust/scripts/build-xcframework.sh`)
#   rig.sh seed-xcf            copy the Rust xcframework into $DIR from FROM=host:dir (default aws-m4pro-6:smooth-lists)
#   rig.sh sim                 create + boot $SIM_NAME ($DEVICE, default iPhone 17 Pro, iOS 26.5) on $HOST
#   rig.sh shot LABEL SCREEN SECS [K=V..]
#                              install and launch as `run` does (no passes: LIST_PASSES=0), wait for the rig's
#                              "holding" line, take LABEL.png SECS seconds later, then terminate the app
#                              (ARGS: extra launch arguments, e.g. `-cmuxMobile.settings.wrapCode YES`)
#   rig.sh build               Demo simulator build on $HOST (arm64 only)
#   rig.sh run LABEL SCREEN [K=V..]
#                              install, launch with CMUX_MOBILE_LIST_SCREEN=SCREEN and CMUX_MOBILE_<K>=V,
#                              wait for the app to exit after the passes, copy framelog.jsonl to
#                              verify/evidence/listperf/LABEL.jsonl. VIDEO=1 also records LABEL.mp4;
#                              SAMPLE=<secs> writes LABEL.sample.txt (`sample` at 1 ms from launch);
#                              TRACE=<template> records LABEL.trace with xctrace (can hang over SSH).
#
# Environment: HOST (default aws-m4pro-6 (it has the iOS 26.5 simulator), reached with Tailscale SSH as ec2-user), DIR (default smooth-lists),
# SIM_NAME (default cmux-listperf-1), WAIT (seconds, default 240), FAMILY (build: TARGETED_DEVICE_FAMILY, e.g. 1,2 for an
# iPad simulator) and PRODUCTS (build/run/shot: derived data folder, default build/demo; give an iPad build its own).
set -euo pipefail
HOST=${HOST:-aws-m4pro-6}
DIR=${DIR:-smooth-lists}
SIM_NAME=${SIM_NAME:-cmux-listperf-1}
here=$(cd "$(dirname "$0")" && pwd)
mobile=$(cd "$here/../.." && pwd)
repo=$(cd "$mobile/.." && pwd)
ts=${TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
# An AWS Mac (aws-m4pro-N) is reached with Tailscale SSH as ec2-user; a cmux mini (mini-*) with its SSH alias.
if [[ $HOST == mini-* ]]; then dest=$HOST; rsh=ssh; else dest=ec2-user@$HOST; rsh="$ts ssh"; fi
remote() { $rsh "$dest" "$@"; }
remote_env='export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer;'

case "${1:-}" in
  sync)
    (cd "$mobile" && xcodegen generate -q)
    rsync -a --delete -e "$rsh" --exclude .build --exclude build --exclude 'verify/' --exclude 'CmuxMobileKit/Frameworks/' \
      --exclude 'rust/target' "$mobile" "$dest:$DIR/"
    rsync -a --delete -e "$rsh" --exclude .build "$repo/Packages" "$dest:$DIR/"
    remote "mkdir -p $DIR/vendor"
    rsync -a -e "$rsh" "$repo/vendor/stack-auth-swift-sdk-prerelease" "$dest:$DIR/vendor/"
    rsync -a -e "$rsh" "$repo/AppIcon.icon" "$dest:$DIR/"
    # Specs the package tests read from the repo (deep links, Full access modes).
    rsync -a --delete -e "$rsh" "$repo/schemas" "$dest:$DIR/"
    remote "mkdir -p $DIR/cmux-tui"
    rsync -a --delete -e "$rsh" "$repo/cmux-tui/spec" "$dest:$DIR/cmux-tui/"
    # rsync keeps mtimes; touch so SwiftPM never reuses an older build of a changed file.
    remote "find $DIR/cmux-next-ios/CmuxMobileKit/Sources -name '*.swift' -newer $DIR/.synced -exec touch {} + 2>/dev/null; touch $DIR/.synced"
    ;;
  seed-xcf)
    # The Rust link library (built once on aws-m4pro-5, see header) for a new DIR or host: FROM=host:dir.
    from=${FROM:-aws-m4pro-6:smooth-lists}
    fhost=${from%%:*} fdir=${from#*:}
    # Copying a directory onto itself would extract over the files tar is still reading.
    if [[ $fhost == "$HOST" && $fdir == "$DIR" ]]; then echo "seed-xcf: FROM is $HOST:$DIR itself; nothing to copy"; exit 0; fi
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
    remote "$remote_env cd $DIR/cmux-next-ios && xcodebuild -project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Demo \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath ${PRODUCTS:-build/demo} -jobs 6 ${FAMILY:+TARGETED_DEVICE_FAMILY=$FAMILY} ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CMUX_MOBILE_TAG=.listperf 'CMUX_MOBILE_DISPLAY_NAME=mobile listperf' \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) DEBUG CMUX_MOBILE_DEMO' build > build-demo.log 2>&1; rc=\$?; \
      grep -E 'error:|BUILD (SUCCEEDED|FAILED)' build-demo.log | sort -u | head -30; exit \$rc"
    ;;
  run)
    label=${2:?label} screen=${3:?screen}; shift 3
    envs="SIMCTL_CHILD_CMUX_MOBILE_FRAMELOG=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=$screen"
    envs+=" SIMCTL_CHILD_CMUX_MOBILE_LIST_EXIT_WHEN_DONE=1"
    for kv in "$@"; do envs+=" SIMCTL_CHILD_CMUX_MOBILE_$kv"; done
    out="$mobile/verify/evidence/listperf"; mkdir -p "$out"
    rec_start=":" rec_stop=":"
    if [[ -n "${VIDEO:-}" ]]; then
      rec_start="rm -f $DIR/$label.mp4; xcrun simctl io \$udid recordVideo --codec h264 --force $DIR/$label.mp4 >/dev/null 2>&1 & rec=\$!; sleep 1"
      rec_stop="kill -INT \$rec; wait \$rec 2>/dev/null || true"
    fi
    launch="$envs perl -e 'alarm shift; exec @ARGV' ${WAIT:-240} xcrun simctl launch --console-pty --terminate-running-process \$udid \$bid \
        -cmuxMobile.setupComplete YES -cmux-mobile-no-restore >/dev/null 2>&1 || true"
    if [[ -n "${SAMPLE:-}" ]]; then
      # xctrace over SSH can hang while finalizing; `sample` at 1 ms needs no authorization.
      launch="pid=\$($envs xcrun simctl launch --terminate-running-process \$udid \$bid \
          -cmuxMobile.setupComplete YES -cmux-mobile-no-restore | awk '{print \$NF}'); \
          sample \$pid $SAMPLE 1 -mayDie -file $DIR/$label.sample.txt >/dev/null 2>&1 || true"
    elif [[ -n "${TRACE:-}" ]]; then
      launch="rm -rf $DIR/$label.trace; pid=\$($envs xcrun simctl launch --terminate-running-process \$udid \$bid \
          -cmuxMobile.setupComplete YES -cmux-mobile-no-restore | awk '{print \$NF}'); \
          xcrun xctrace record --no-prompt --template '$TRACE' --device \$udid --attach \$pid --time-limit ${WAIT:-240}s \
          --output $DIR/$label.trace >$DIR/$label.xctrace.log 2>&1 || true"
    fi
    remote "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      app=\$(ls -d $DIR/cmux-next-ios/${PRODUCTS:-build/demo}/Build/Products/Demo-iphonesimulator/*.app | head -1); \
      bid=\$(plutil -extract CFBundleIdentifier raw \$app/Info.plist); \
      xcrun simctl terminate \$udid \$bid 2>/dev/null; xcrun simctl install \$udid \$app; \
      caches=\$(xcrun simctl get_app_container \$udid \$bid data)/Library/Caches; rm -f \$caches/framelog.jsonl; \
      $rec_start; $launch; $rec_stop; \
      cat \$caches/framelog.jsonl; \
      xcrun simctl spawn \$udid log show --last 6m --predicate 'subsystem == \"dev.cmux.mobile\" AND category == \"frames\"' --style compact 2>/dev/null \
        | grep -E 'list-stress (memory|pass|tabs|rowcost|axtree)' | sed 's/^/# /'" > "$out/$label.jsonl"
    [[ -n "${SAMPLE:-}" ]] && remote "cat $DIR/$label.sample.txt" > "$out/$label.sample.txt" && echo "sample: $out/$label.sample.txt"
    [[ -n "${VIDEO:-}" ]] && remote "cat $DIR/$label.mp4" > "$out/$label.mp4" && echo "video: $out/$label.mp4"
    if [[ -n "${TRACE:-}" ]]; then
      rm -rf "$out/$label.trace"
      remote "cd $DIR && tar cf - $label.trace" | (cd "$out" && tar xf -) && echo "trace: $out/$label.trace"
    fi
    python3 "$mobile/verify/feedperf/summarize.py" "$out/$label.jsonl"
    ;;
  shot)
    label=${2:?label} screen=${3:?screen} secs=${4:?seconds}; shift 4
    envs="SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=$screen SIMCTL_CHILD_CMUX_MOBILE_LIST_PASSES=0"
    for kv in "$@"; do envs+=" SIMCTL_CHILD_CMUX_MOBILE_$kv"; done
    out="$mobile/verify/evidence/listperf"; mkdir -p "$out"
    remote "$remote_env udid=\$(xcrun simctl list devices | grep '$SIM_NAME (' | head -1 | grep -oE '[0-9A-F-]{36}'); \
      app=\$(ls -d $DIR/cmux-next-ios/${PRODUCTS:-build/demo}/Build/Products/Demo-iphonesimulator/*.app | head -1); \
      bid=\$(plutil -extract CFBundleIdentifier raw \$app/Info.plist); \
      xcrun simctl terminate \$udid \$bid 2>/dev/null; xcrun simctl install \$udid \$app; \
      pid=\$($envs xcrun simctl launch --terminate-running-process \$udid \$bid -cmuxMobile.setupComplete YES -cmux-mobile-no-restore ${ARGS:-} | awk '{print \$NF}'); \
      for i in \$(seq 1 60); do xcrun simctl spawn \$udid log show --last 30s --predicate 'subsystem == \"dev.cmux.mobile\"' --style compact 2>/dev/null \
        | grep \"\\[\$pid:\" | grep -q 'list-stress holding' && break; sleep 3; done; sleep $secs; rm -f $DIR/$label.png; xcrun simctl io \$udid screenshot $DIR/$label.png >/dev/null 2>&1; \
      xcrun simctl terminate \$udid \$bid 2>/dev/null; true"
    remote "cat $DIR/$label.png" > "$out/$label.png" && echo "shot: $out/$label.png"
    ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
