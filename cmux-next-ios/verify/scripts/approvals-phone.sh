#!/bin/bash
# The phone side of verify/phone-approvals.md: one headless simulator, a Debug
# build, signed in with the DEBUG agent credential (CMUX_MOBILE_STACK_EMAIL and
# CMUX_MOBILE_STACK_PASSWORD in the environment, passed as SIMCTL_CHILD_*; never
# printed), pointed at one Mac, running `-cmux-mobile-demo approve` with a plan.
#
# usage: approvals-phone.sh launch UDID OUT TEAM MAC PLAN [extra args...]
#        approvals-phone.sh enroll UDID | match UDID | nomatch UDID
#        approvals-phone.sh shot UDID FILE | stop UDID OUT
set -u
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUNDLE=dev.cmux.mobile

case ${1:-} in
launch)
  udid=$2 out=$3 team=$4 mac=$5 plan=$6; shift 6
  mkdir -p "$out"
  xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  nohup xcrun simctl spawn "$udid" log stream --level info \
    --predicate 'subsystem == "dev.cmux.mobile" OR process == "CmuxMobileApp"' --style compact >> "$out/app.log" 2>&1 &
  echo $! > "$out/log.pid"
  SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL="$CMUX_MOBILE_STACK_EMAIL" SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD="$CMUX_MOBILE_STACK_PASSWORD" \
    xcrun simctl launch "$udid" "$BUNDLE" -cmux-mobile-demo approve -cmuxMobile.demo.approve "$plan" \
    -cmuxMobile.setupComplete 1 "-cmuxMobile.live.mac.$team" "$mac" "$@"
  ;;
enroll)
  xcrun simctl spawn "$2" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
  xcrun simctl spawn "$2" notifyutil -p com.apple.BiometricKit.enrollmentChanged
  ;;
match) xcrun simctl spawn "$2" notifyutil -p com.apple.BiometricKit_Sim.pearl.match ;;
nomatch) xcrun simctl spawn "$2" notifyutil -p com.apple.BiometricKit_Sim.pearl.nomatch ;;
shot) xcrun simctl io "$2" screenshot "$3" > /dev/null ;;
stop)
  xcrun simctl terminate "$2" "$BUNDLE" 2>/dev/null || true
  kill "$(cat "$3/log.pid" 2>/dev/null)" 2>/dev/null || true
  ;;
*) sed -n 2,10p "$0"; exit 2 ;;
esac
