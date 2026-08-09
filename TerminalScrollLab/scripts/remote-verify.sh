#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

(
  cd ghostty
  zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
)
if [[ ! -d GhosttyKit.xcframework ]]; then
  echo "GhosttyKit.xcframework was not produced" >&2
  exit 1
fi

runtime_id="$({
  xcrun simctl list runtimes -j \
    | jq -r '.runtimes[] | select(.platform == "iOS" and .isAvailable == true) | .identifier'
} | tail -n 1)"
if [[ -z "$runtime_id" ]]; then
  echo "No available iOS Simulator runtime" >&2
  exit 1
fi

simulator_name="TerminalScrollLab-iscrol-$$"
simulator_udid="$({
  xcrun simctl create \
    "$simulator_name" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max \
    "$runtime_id"
})"
if [[ -z "$simulator_udid" ]]; then
  echo "Failed to create isolated simulator" >&2
  exit 1
fi
cleanup() {
  xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcodebuild \
  -project TerminalScrollLab/TerminalScrollLab.xcodeproj \
  -scheme TerminalScrollLab \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$repo_root/.terminal-scroll-lab-derived-data" \
  test
