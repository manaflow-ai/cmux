#!/usr/bin/env bash
# Checks that a built cmux-next-ios app carries none of the DEBUG-only surface:
# launch overrides, the Developer page, demo drivers, and mock content (the
# mock terminal script, mock agent/Feed/Chief scripts, sample data). Mock code
# is compiled out with `#if DEBUG`; this proves it on the binary.
#
# usage: cmux-next-ios/scripts/check-production-binary.sh <CmuxMobileApp.app> [expected bundle id] [--shipping | --staging-shipping]
#
# --shipping (TestFlight and App Store builds): the service address must be a
# production one, never the dev Worker or a local server.
# --staging-shipping (TestFlightStaging): the service address must be exactly
# the dev Worker that staging builds use, never a local server.
#
# Scans every Mach-O in the bundle (SwiftPM products can be dynamic; Debug
# builds keep their code in CmuxMobileApp.debug.dylib). Exits 1 and names each string it found.
set -euo pipefail

app=${1:?usage: check-production-binary.sh <CmuxMobileApp.app> [expected bundle id]}
expected_bundle=${2:-}
shipping=0; [[ "${3:-}" == --shipping ]] && shipping=1
staging=0; [[ "${3:-}" == --staging-shipping ]] && staging=1
staging_api=https://cmux-mobile-api-dev.debussy.workers.dev
[[ -d "$app" ]] || { echo "error: $app is not an app bundle" >&2; exit 2; }

# Each string exists only in DEBUG code. Literals are longer than 15 bytes
# (shorter Swift literals are stored inline, not as C strings) or are type
# names (kept in the reflection metadata).
forbidden=(
  # Launch overrides and the Developer page.
  CMUX_MOBILE_MOCK_AUTH CMUX_MOBILE_STACK_EMAIL CMUX_MOBILE_CLEAR_AUTH "Demo at next launch" -cmux-mobile-demo
  "Mock data signs in as a sample user" "Slow mock Face ID"
  # Demo drivers.
  DemoDriver TerminalDemoRoot TerminalDemoDriver FakeCodexSession FeedDemoScript ParityDemoScript OnboardingDemoScript
  # The mock terminal: its session, its scripted shell, a fake git log line.
  MockTerminalSession MockOutput "cmux-next-ios: design specification" "hostd: splice daemon channel with allowlist"
  # Mock agent chat, Feed, Chief, artifacts and workspaces.
  MockAgentSession "Every link frame is a fixed 9-byte header"
  "Which channel should this build go to first?"
  ChiefMockBackend "Overnight: Codex finished the pricing page fix"
  MockArtifactSource MockWorkspaceCreationBackend
  # Demo choreography, the mock terminal screen's "Mock session · local"
  # label (strings stops at the middle dot), the mock sign-in
  # user, and the old fake terminal placeholder page.
  DemoDirector WorkspaceDemoDirector "Mock session" "aziz@example.com"
  "Last login: Sun Oct 12" "Live terminal arrives with CmuxMobileTerminal"
)

# Every Mach-O in the bundle: the executable, Frameworks/, and the
# `<name>.debug.dylib` Xcode splits a Debug build's code into.
binaries=()
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O && binaries+=("$f")
done < <(find "$app" -type f -print0)
[[ ${#binaries[@]} -gt 0 ]] || { echo "error: no Mach-O binaries in $app" >&2; exit 2; }

bad=()
if [[ -n "$expected_bundle" ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")" == "$expected_bundle" ]] || bad+=("bundle id")
  api_base=$(plutil -extract CmuxMobileAPIBase raw "$app/Info.plist" 2>/dev/null || true)
  [[ "$api_base" == https://* ]] || bad+=("CmuxMobileAPIBase")
  # Production talks to the production Worker, never a dev deployment.
  if [[ $staging == 1 ]]; then
    [[ "$api_base" == "$staging_api" ]] || bad+=("CmuxMobileAPIBase '$api_base' is not the staging Worker $staging_api")
  else
    [[ "$api_base" != *-dev* ]] || bad+=("CmuxMobileAPIBase is a dev Worker ($api_base)")
  fi
fi
if [[ $shipping == 1 ]]; then
  api=$(plutil -extract CmuxMobileAPIBase raw "$app/Info.plist" 2>/dev/null || true)
  [[ "$api" == https://* && ! "$api" =~ (-dev[.-]|localhost|127\.0\.0\.1|\.local) ]] \
    || bad+=("CmuxMobileAPIBase '$api' is not a production service address")
fi
dump=$(mktemp)
trap 'rm -f "$dump"' EXIT
for b in "${binaries[@]}"; do strings -a "$b"; done > "$dump"
for s in "${forbidden[@]}"; do
  if grep -qF -- "$s" "$dump"; then bad+=("DEBUG string '$s'"); fi
done

if [[ ${#bad[@]} -gt 0 ]]; then
  echo "error: $app is not a clean Production build:" >&2
  printf '  - %s\n' "${bad[@]}" >&2
  exit 1
fi
echo "ok: $app has no DEBUG-only strings (${#binaries[@]} binaries, ${#forbidden[@]} strings checked)"
