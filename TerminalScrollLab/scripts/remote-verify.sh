#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

source "$repo_root/scripts/ghostty-zig-version.sh"
required_zig="$(ghostty_minimum_zig_version "$repo_root")"
zig_binary="${CMUX_ZIG:-}"
for candidate in "$zig_binary" /opt/homebrew/bin/zig /usr/local/bin/zig "$(command -v zig 2>/dev/null || true)"; do
  if [[ -x "$candidate" ]] && ghostty_zig_version_is_compatible "$($candidate version)" "$required_zig"; then
    zig_binary="$candidate"
    break
  fi
done
if [[ ! -x "$zig_binary" ]] || ! ghostty_zig_version_is_compatible "$($zig_binary version)" "$required_zig"; then
  echo "Ghostty requires Zig $required_zig" >&2
  exit 1
fi

(
  cd ghostty
  "$zig_binary" build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
)
if [[ ! -d ghostty/macos/GhosttyKit.xcframework ]]; then
  echo "GhosttyKit.xcframework was not produced" >&2
  exit 1
fi
ln -sfn ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

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
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b
recording_pid=""
if [[ -n "${EVIDENCE_VIDEO:-}" ]]; then
  mkdir -p "$(dirname "$EVIDENCE_VIDEO")"
  xcrun simctl io "$simulator_udid" recordVideo --force "$EVIDENCE_VIDEO" &
  recording_pid="$!"
fi
cleanup() {
  if [[ -n "$recording_pid" ]]; then
    kill -INT "$recording_pid" >/dev/null 2>&1 || true
    wait "$recording_pid" >/dev/null 2>&1 || true
  fi
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
