#!/usr/bin/env bash
# Records the pairing fixes (verify/pairing.md) on one headless simulator in
# mock mode, splits every recording into frames and OCRs them:
#   onboarding   cold launch signed out, email sign-in, setup with a slow team
#                list (CMUX_MOBILE_MOCK_TEAMS_DELAY=2): loading, never Create Team
#   elsewhere    setup "Connect your Mac" with the Mac coming online in another
#                team: the phone follows it there
#   empty        Workspaces with no Mac in the active team: names the team and
#                offers the team with a Mac, then switches
# usage: verify/record-pairing.sh <udid> <out dir> [fps]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 out=$2 fps=${3:-30}
mkdir -p "$out"
setup_done() { xcrun simctl spawn "$udid" defaults write dev.cmux.mobile cmuxMobile.setupComplete -bool "$1"; }
split() { # video name
  mkdir -p "$out/$2"
  ffmpeg -loglevel error -y -i "$1" -vf "fps=$fps,scale=402:-1" "$out/$2/f%04d.png"
  swift verify/scripts/ocr-frames.swift "$out/$2"/f*.png > "$out/$2.ocr.tsv"
}
setup_done false
CMUX_MOBILE_MOCK_AUTH=1 CMUX_MOBILE_CLEAR_AUTH=1 CMUX_MOBILE_MOCK_TEAMS_DELAY=2 verify/record.sh "$udid" "$out/onboarding.mp4" 18 dark -cmux-mobile-demo onboarding
split "$out/onboarding.mp4" onboarding
setup_done false
CMUX_MOBILE_MOCK_AUTH=1 verify/record.sh "$udid" "$out/elsewhere.mp4" 9 dark -cmux-mobile-setup-pair -cmux-mobile-setup-pair-elsewhere
split "$out/elsewhere.mp4" elsewhere
setup_done true
CMUX_MOBILE_MOCK_AUTH=1 verify/record.sh "$udid" "$out/empty.mp4" 10 dark -cmux-mobile-demo connect-mac-elsewhere
split "$out/empty.mp4" empty
echo "$out"
