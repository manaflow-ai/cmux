#!/usr/bin/env bash
# Demo and production builds of cmux-next-ios from one committed SHA, for hand
# installs and feedback. Nothing is uploaded anywhere (no App Store, no TestFlight).
#
# usage: cmux-next-ios/scripts/demo-build.sh [--config Demo|Production] [--ref <git ref>]
#          [--tag <tag>] [--install-device <udid>] [--skip-device] [--skip-mac] [--strict]
#
# Every build first runs scripts/check-tabskit-sync.sh: CmuxTabsKit and
# CmuxConversation must be byte-identical to their upstream branches
# (feat-cmux-next-tabs-kit, feat-imsg-parity-gui). Drift prints a loud warning
# and is recorded in MANIFEST.md; --strict makes it fail the build.
#
# Output: ~/cmux-mobile-builds/<UTC date>-<shortsha>[-<tag>]/
#   ios-device/cmux-mobile-<tag>.ipa            Demo config, bundle dev.cmux.mobile.<tag>
#   ios-simulator/cmux-mobile-<tag>-sim.app.zip `xcrun simctl install <udid> <unzipped .app>`
#   cmux-mobile-host-macos-arm64/ (+ .tar.gz)   Mac side: bin/, run-host.sh, stop-host.sh, README.txt
#   MANIFEST.md
#
# The "Demo" configuration is optimized (-O) and keeps the DEBUG developer
# surface: dev sign-in ("42" as the email), Settings → Developer (mock data,
# scripted demos), the dev Worker. The source is `git archive` of the SHA, so
# uncommitted changes never reach a demo build.
#
# --config Production builds the "Production" configuration instead: -O, no
# DEBUG (no dev sign-in, no Settings → Developer, no mock data or demo
# drivers), the production Stack project, bundle dev.cmux.mobile.prod ("cmux
# mobile") beside the demo install, and the production Worker
# (https://mobile-api.cmux.dev, production Stack users only). Its tag is always "prod": ~/cmux-mobile-builds/<date>-<sha>-prod/.
#
# Environment:
#   CMUX_MOBILE_BUILDS_ROOT      output root (default ~/cmux-mobile-builds)
#   CMUX_MOBILE_MAC_BUILD_HOST   ssh host that builds the Mac binaries (default
#                        mini-cmuxs-mac-mini-2; Rust builds never run on this laptop)
#   CMUX_MOBILE_MAC_BUILD_DIR    build dir on that host, relative to its home
#                        (default cmux-next-ios-e2e/demo-build; cargo targets are kept there)
#   CMUX_MOBILE_XCFRAMEWORK      use this CmuxMobileLinkFFI.xcframework instead of building or the cache
#   JOBS                 cargo parallelism (default 8)
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ref=HEAD tag=demo install_device="" skip_device=0 skip_mac=0 build_config=Demo strict=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) build_config=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --tag) tag=$2; shift 2 ;;
    --install-device) install_device=$2; shift 2 ;;
    --skip-device) skip_device=1; shift ;;
    --skip-mac) skip_mac=1; shift ;;
    --strict) strict=1; shift ;;
    -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$build_config" in
  Demo) [[ "$tag" != prod ]] || { echo "error: tag prod is the Production build's; use --config Production" >&2; exit 2; } ;;
  Production) tag=prod ;;
  *) echo "error: --config must be Demo or Production" >&2; exit 2 ;;
esac
[[ "$tag" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "error: tag must be lowercase letters, digits, dashes" >&2; exit 2; }

team=7WLXT3NR37
bundle_id="dev.cmux.mobile.$tag"
display_name="cmux mobile"; [[ "$tag" == demo || "$tag" == prod ]] || display_name="mobile $tag"
jobs=${JOBS:-8}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$script_dir" rev-parse --show-toplevel)
sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")
short=${sha:0:10}
root=${CMUX_MOBILE_BUILDS_ROOT:-$HOME/cmux-mobile-builds}
name="$(date -u +%Y%m%d)-$short"; [[ "$tag" == demo ]] || name+="-$tag"
out="$root/$name"
work="$root/.work/$name"
cache="$root/.cache"
mac_host=${CMUX_MOBILE_MAC_BUILD_HOST:-mini-cmuxs-mac-mini-2}
mac_dir=${CMUX_MOBILE_MAC_BUILD_DIR:-cmux-next-ios-e2e/demo-build}
log() { printf '\n==> %s\n' "$*"; }
notes=()   # known build-time issues for the manifest

# --- Shared packages must match upstream ----------------------------------
log "shared packages vs upstream"
sync_status=0
sync_report=$("$script_dir/check-tabskit-sync.sh" --ref "$sha" 2>&1) || sync_status=$?
echo "$sync_report"
if [[ $sync_status != 0 ]]; then
  printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
  printf '!!  %s: shared iOS packages are NOT the latest upstream.\n' "$([[ $strict == 1 ]] && echo ERROR || echo WARNING)" >&2
  printf '!!  Sync them (see above) or this build ships stale TabsKit/Conversation UX.\n' >&2
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n' >&2
  [[ $strict == 0 ]] || exit 1
  notes+=("Shared packages differ from upstream (check-tabskit-sync.sh): $(grep -E '^(DRIFT|error)' <<<"$sync_report" | paste -sd ';' -)")
fi

rm -rf "$out" "$work"
mkdir -p "$out" "$work/src" "$work/logs" "$cache"
log "cmux-next-ios $build_config build $sha (tag $tag) -> $out"

# --- Source ---------------------------------------------------------------
# Everything the app and the Rust crates read, from the commit only.
paths=(cmux-next-ios Packages vendor/stack-auth-swift-sdk-prerelease AppIcon.icon
       cmux-tui schemas backend/catalog backend/packages plans/cmux-next skills mux samples)
git -C "$repo" archive --format=tar "$sha" "${paths[@]}" | tar -x -C "$work/src"
ghostty_sha=$(git -C "$repo" ls-tree "$sha" ghostty-next | awk '{print $3}')

# --- CmuxMobileLinkFFI.xcframework (gitignored; keyed on the Rust sources) -----------
key=$(printf '%s\n' "$(git -C "$repo" rev-parse "$sha:cmux-next-ios/rust")" \
  "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-wg")" \
  "$(git -C "$repo" rev-parse "$sha:cmux-tui/crates/cmux-transport")" | shasum | cut -c1-16)
xcf_dest="$work/src/cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
mkdir -p "$(dirname "$xcf_dest")"
if [[ -n "${CMUX_MOBILE_XCFRAMEWORK:-}" ]]; then
  log "xcframework: using $CMUX_MOBILE_XCFRAMEWORK"
  cp -R "$CMUX_MOBILE_XCFRAMEWORK" "$xcf_dest"
  notes+=("CmuxMobileLinkFFI.xcframework came from CMUX_MOBILE_XCFRAMEWORK, not built from this SHA.")
elif [[ -d "$cache/xcframework/$key/CmuxMobileLinkFFI.xcframework" ]]; then
  log "xcframework: cache hit $key"
  cp -R "$cache/xcframework/$key/CmuxMobileLinkFFI.xcframework" "$xcf_dest"
else
  log "xcframework: building (key $key)"
  mkdir -p "$cache/cmux-mobile-rust-target"
  ln -s "$cache/cmux-mobile-rust-target" "$work/src/cmux-next-ios/rust/target"
  JOBS=$jobs bash "$work/src/cmux-next-ios/rust/scripts/build-xcframework.sh" > "$work/logs/xcframework.log" 2>&1 \
    || { tail -30 "$work/logs/xcframework.log"; exit 1; }
  git -C "$repo" show "$sha:cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift" \
    | cmp -s - "$work/src/cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift" \
    || notes+=("The generated CmuxMobileLinkFFI.swift differs from the committed copy; the build used the regenerated one.")
  rm -rf "$cache/xcframework/$key"; mkdir -p "$cache/xcframework/$key"
  cp -R "$xcf_dest" "$cache/xcframework/$key/"
fi

# --- iOS builds -----------------------------------------------------------
cd "$work/src/cmux-next-ios"
xcodegen generate -q
config=$build_config
# Refs before the CmuxMobileDesign ToastHost fix fail to link at -O (default CMO
# inlines a public .task(id:) caller into other modules); build them -Osize.
opt=-O
grep -q 'struct ToastHost' CmuxMobileKit/Sources/CmuxMobileDesign/States.swift || { opt=-Osize; notes+=("This ref predates the -O link fix; built with -Osize."); }
common=(-project CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration "$config"
        -clonedSourcePackagesDirPath "$cache/spm"
        SWIFT_OPTIMIZATION_LEVEL=$opt
        MARKETING_VERSION="${CMUX_MOBILE_MARKETING_VERSION:-0.1.0}"
        CURRENT_PROJECT_VERSION="$(git -C "$repo" rev-list --count "$sha")")
if [[ $config == Production ]]; then
  # Everything (bundle id, name, Stack project, service, entitlements, no
  # DEBUG) comes from the Production configuration in project.yml.
  grep -q '^  Production: release' project.yml || { echo "error: $sha has no Production configuration" >&2; exit 1; }
else
  # Refs from before the Demo configuration build Debug with the same overrides.
  grep -q '^  Demo: release' project.yml || { config=Debug; notes+=("This ref has no Demo configuration; built Debug (no Settings → Developer)."); }
  common+=(CMUX_MOBILE_TAG=".$tag" "CMUX_MOBILE_DISPLAY_NAME=$display_name"
           # $(inherited) keeps each package's own conditions (swift-crypto needs them).
           'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO')
fi
xcb() { local logf=$1; shift; xcodebuild "$@" > "$logf" 2>&1 || { grep -E "error:|BUILD FAILED" "$logf" | sort -u | head -20; return 1; }; }

log "iOS simulator build"
xcb "$work/logs/ios-simulator.log" "${common[@]}" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/dd-sim" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
sim_app="$work/dd-sim/Build/Products/$config-iphonesimulator/CmuxMobileApp.app"
mkdir -p "$out/ios-simulator"
ditto -c -k --keepParent "$sim_app" "$out/ios-simulator/cmux-mobile-$tag-sim.app.zip"
app_version=$(plutil -extract CFBundleShortVersionString raw "$sim_app/Info.plist" 2>/dev/null || echo "?")
app_build=$(plutil -extract CFBundleVersion raw "$sim_app/Info.plist" 2>/dev/null || echo "?")

# A Production build must carry none of the DEBUG surface (launch overrides,
# the Developer page, demo drivers, mock terminal/agent/Feed/Chief content)
# and the right identity. The check is tooling: it comes with this script, not the ref.
check_production() {  # <app dir>
  bash "$script_dir/check-production-binary.sh" "$1" "$bundle_id"
}
[[ $config != Production ]] || check_production "$sim_app"

# A development profile for the bundle (or the team wildcard) whose
# certificate is in this keychain. Prints "<uuid> <cert sha1>".
find_profile() {
  local ids f tmp
  ids=$(security find-identity -v -p codesigning | awk '/[0-9A-F]{40}/{print $2}')
  tmp=$(mktemp)
  for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
           "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
    [[ -f "$f" ]] || continue
    security cms -D -i "$f" > "$tmp" 2>/dev/null || continue
    local app exp uuid
    app=$(plutil -extract Entitlements.application-identifier raw -o - "$tmp" 2>/dev/null) || continue
    [[ "$app" == "$team.$bundle_id" || "$app" == "$team.*" ]] || continue
    plutil -extract ProvisionedDevices raw -o - "$tmp" >/dev/null 2>&1 || continue  # development only
    exp=$(plutil -extract ExpirationDate raw -o - "$tmp")
    [[ "$exp" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || continue
    uuid=$(plutil -extract UUID raw -o - "$tmp")
    local i=0 cert
    while cert=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$tmp" 2>/dev/null); do
      local fp; fp=$(base64 -d <<<"$cert" | shasum | awk '{print toupper($1)}')
      if grep -qx "$fp" <<<"$ids"; then rm -f "$tmp"; echo "$uuid $fp"; return 0; fi
      i=$((i+1))
    done
  done
  rm -f "$tmp"; return 1
}

device_ipa="" signing="not built"
if [[ $skip_device == 0 ]]; then
  log "iOS device build"
  dev_args=("${common[@]}" -destination 'generic/platform=iOS' -derivedDataPath "$work/dd-device")
  if xcb "$work/logs/ios-device-auto.log" "${dev_args[@]}" -allowProvisioningUpdates \
       CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$team build; then
    signing="automatic (team $team)"
  elif read -r profile cert < <(find_profile); then
    echo "automatic signing unavailable (see logs/ios-device-auto.log); using profile $profile"
    xcb "$work/logs/ios-device.log" "${dev_args[@]}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$team \
      CODE_SIGN_IDENTITY="$cert" PROVISIONING_PROFILE_SPECIFIER="$profile" build
    signing="manual, development profile $profile (team $team)"
  else
    signing="failed: no account for automatic signing and no development profile for $bundle_id"
    notes+=("Device build not signed: $signing. Sign in to Xcode with a team $team account, or install a development profile, then rerun.")
  fi
  dev_app="$work/dd-device/Build/Products/$config-iphoneos/CmuxMobileApp.app"
  if [[ "$signing" != failed* && -d "$dev_app" ]]; then
    mkdir -p "$work/ipa/Payload" "$out/ios-device"
    cp -R "$dev_app" "$work/ipa/Payload/"
    (cd "$work/ipa" && zip -qry "$out/ios-device/cmux-mobile-$tag.ipa" Payload)
    device_ipa="$out/ios-device/cmux-mobile-$tag.ipa"
    devices=$(security cms -D -i "$dev_app/embedded.mobileprovision" 2>/dev/null \
      | plutil -extract ProvisionedDevices json -o - - 2>/dev/null || echo '[]')
    keychain_groups=$(codesign -d --entitlements - --xml "$dev_app" 2>/dev/null \
      | plutil -extract keychain-access-groups json -o - - 2>/dev/null || echo '[]')
    [[ $config != Production ]] || check_production "$dev_app"
  fi
fi

# --- Mac host package -----------------------------------------------------
pkg="$out/cmux-mobile-host-macos-arm64"
mac_versions=""
if [[ $skip_mac == 0 ]]; then
  log "Mac binaries on $mac_host:~/$mac_dir"
  ssh -o BatchMode=yes "$mac_host" "rm -rf ~/$mac_dir/src && mkdir -p ~/$mac_dir/src"
  git -C "$repo" archive --format=tar "$sha" cmux-tui cmux-next-ios/rust \
    Packages/macOS/CmuxNext/Sources/CmuxNextMobile schemas backend/catalog backend/packages \
    plans/cmux-next skills mux samples | ssh "$mac_host" "tar -x -C ~/$mac_dir/src"
  # ghostty-next is a submodule: archive it from its own repository.
  [[ -e "$repo/ghostty-next/.git" ]] || git -C "$repo" submodule update --init --depth 1 ghostty-next
  if ! git -C "$repo/ghostty-next" cat-file -e "$ghostty_sha^{commit}" 2>/dev/null; then
    # --depth only in an already-shallow submodule; it would make a full one shallow.
    depth=()
    [[ "$(git -C "$repo/ghostty-next" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    git -C "$repo/ghostty-next" fetch ${depth[@]+"${depth[@]}"} origin "$ghostty_sha"
  fi
  git -C "$repo/ghostty-next" archive --format=tar --prefix=ghostty-next/ "$ghostty_sha" \
    | ssh "$mac_host" "tar -x -C ~/$mac_dir/src"
  ssh "$mac_host" "set -e; export PATH=\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH; d=\$HOME/$mac_dir
    cd \$d/src/cmux-next-ios/rust && CARGO_TARGET_DIR=\$d/target-mobile cargo build --release --locked -j $jobs -p cmux-mobile-host --bin cmux-mobile-host
    cd \$d/src/cmux-tui && CMUX_GIT_SHORT_SHA=${sha:0:9} CMUX_TUI_BUILD_COMMIT=$sha CARGO_TARGET_DIR=\$d/target-tui \
      cargo build --release --locked -j $jobs -p cmux-tui -p acpmux --bin cmux-tui --bin acpmux" \
    > "$work/logs/mac-binaries.log" 2>&1 || { tail -30 "$work/logs/mac-binaries.log"; exit 1; }
  mac_versions=$(ssh "$mac_host" "d=\$HOME/$mac_dir; \$d/target-tui/release/cmux-tui --version 2>&1 | head -1; \
    \$d/target-tui/release/acpmux --version 2>&1 | head -1")
  mkdir -p "$pkg/bin"
  ssh "$mac_host" "d=\$HOME/$mac_dir; tar -c -C \$d/target-tui/release cmux-tui acpmux -C \$d/target-mobile/release cmux-mobile-host" \
    | tar -x -C "$pkg/bin"
  for b in "$pkg"/bin/*; do
    codesign --force --sign - --identifier "dev.cmux.mobile.host.$(basename "$b")" "$b"
  done
  # The host scripts are tooling: they come with this script, not the ref.
  cp "$script_dir/host/run-host.sh" "$script_dir/host/stop-host.sh" "$script_dir/host/README.txt" "$pkg/"
  chmod 755 "$pkg/run-host.sh" "$pkg/stop-host.sh"
  echo "$sha" > "$pkg/SOURCE_SHA"
  tar -c -z -C "$out" -f "$out/cmux-mobile-host-macos-arm64.tar.gz" cmux-mobile-host-macos-arm64
fi

# --- Optional install on a phone -----------------------------------------
installed=""
if [[ -n "$install_device" && -n "$device_ipa" ]]; then
  log "installing on $install_device"
  xcrun devicectl device install app --device "$install_device" "$dev_app" && installed="$install_device"
fi

# --- Manifest -------------------------------------------------------------
production_manifest() {
  cat <<EOF
# cmux-next-ios production build $name

| | |
| --- | --- |
| Commit | \`$sha\` ($(git -C "$repo" log -1 --format='%s' "$sha")) |
| Built | $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(scutil --get LocalHostName 2>/dev/null || hostname), $(xcodebuild -version | head -1)$([[ $skip_mac == 1 ]] || echo ", Mac binaries on \`$mac_host\`") |
| App | "$display_name", bundle \`$bundle_id\`, version $app_version ($app_build), configuration Production ($opt, no DEBUG), iOS 26.0+ |
| Device signing | $signing |
| Keychain access groups | $(echo "${keychain_groups:-[]}" | tr -d '\n ') (its own group; no app group: the app shares no container) |

Not for the App Store or TestFlight; nothing here was uploaded. It installs
beside the demo build (\`dev.cmux.mobile.demo\`); both are named "cmux mobile".

## Production vs dev, exactly

| Part | This build |
| --- | --- |
| Compilation | Production configuration: Release optimization ($opt), \`CMUX_MOBILE_PRODUCTION\`, no \`DEBUG\` in the app or any package. The build checks the binaries for DEBUG-only strings. |
| Stack Auth | **Production** project \`9790718f-14cd-4f7e-824d-eaf527a82b82\`, no publishable key, email callback \`https://cmux.com/auth/callback\` (CmuxAuthRuntime \`AuthConfig(environment: .production)\`). Sign in with a real account: email code, Google or GitHub. |
| Backend | **Production** Worker \`https://mobile-api.cmux.dev\` (\`cmux-mobile-api-prod\`, API 0.7.0 or later, its own database), which accepts production Stack users only. \`./run-host.sh --prod\` uses it too. |
| Developer surface | None: no "42" dev sign-in, no Settings → Developer, no mock data toggle, no scripted demos, no launch overrides (\`scripts/check-production-binary.sh\` passed). |
| Error reporting | None (the app has none configured). |
| Data before a Mac links | Empty: no sample teams, Macs, Feed, chats or Chief. A terminal tab without its Mac session shows "Connecting to <Mac>…", never sample output. Mock code is compiled out, and stored developer settings from an earlier Debug or Demo install are removed at launch. |

## Contents

- \`ios-device/cmux-mobile-$tag.ipa\`: the phone build. Provisioned devices: $(echo "${devices:-[]}" | tr -d '\n ' ).
- \`ios-simulator/cmux-mobile-$tag-sim.app.zip\`: the simulator build (arm64).
$([[ $skip_mac == 1 ]] || echo "- \`cmux-mobile-host-macos-arm64/\` and \`.tar.gz\`: the Mac side; start it with \`./run-host.sh --prod\`.")

## Install

- Phone: \`unzip -q ios-device/cmux-mobile-$tag.ipa -d /tmp/cmux-mobile-prod && xcrun devicectl device install app --device <udid> /tmp/cmux-mobile-prod/Payload/CmuxMobileApp.app\`.
- Simulator: \`ditto -x -k ios-simulator/cmux-mobile-$tag-sim.app.zip /tmp/cmux-mobile-prod-sim && xcrun simctl install <udid> /tmp/cmux-mobile-prod-sim/CmuxMobileApp.app && xcrun simctl launch <udid> $bundle_id\`.
- Mac: \`./run-host.sh --prod\` (from this or a demo build's host package, if its run-host.sh has \`--prod\`). It signs in to the **production** Stack project, with its own state in \`~/.cmux-mobile-host-prod\` beside a dev host in \`~/.cmux-mobile-host\`. \`./stop-host.sh --prod\` stops it. Use the phone's production account: the phone and the Mac must be the same user in the same project.

## Known gaps

- Sign in with Apple needs the Sign in with Apple capability and an Apple client for \`$bundle_id\` in the production Stack project. Neither exists, so use email, Google or GitHub.
- Team invitation emails link to \`https://cmux.com/handler/team-invitation\`.
- The demo build's known gaps apply too: no terminal over the link, agent permissions can only be denied, and Chief over the link is not allowlisted.
EOF
}

{
  if [[ $config == Production ]]; then production_manifest; else
  cat <<EOF
# cmux-next-ios demo build $name

| | |
| --- | --- |
| Commit | \`$sha\` ($(git -C "$repo" log -1 --format='%s' "$sha")) |
| Built | $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(scutil --get LocalHostName 2>/dev/null || hostname), $(xcodebuild -version | head -1), Mac binaries on \`$mac_host\` |
| App | "$display_name", bundle \`$bundle_id\`, version $app_version ($app_build), configuration $config ($opt, DEBUG developer surface), iOS 26.0+ |
| Device signing | $signing |
| Mac host | $(echo "$mac_versions" | paste -sd ';' - | sed 's/;/; /g'), cmux-mobile-host from \`cmux-next-ios/rust\` (arm64, ad-hoc signed) |
| Service | dev Worker \`https://cmux-mobile-api-dev.debussy.workers.dev\`, Stack dev project |

Not for the App Store or TestFlight; nothing here was uploaded.

## Contents

- \`ios-device/cmux-mobile-$tag.ipa\`: the phone build. Provisioned devices: $(echo "${devices:-[]}" | tr -d '\n ' ).
- \`ios-simulator/cmux-mobile-$tag-sim.app.zip\`: the simulator build (arm64).
- \`cmux-mobile-host-macos-arm64/\` and \`.tar.gz\`: the Mac side (\`bin/cmux-mobile-host\`, \`bin/cmux-tui\`, \`bin/acpmux\`, \`run-host.sh\`, \`stop-host.sh\`, \`README.txt\`).

## Install

- Phone (USB or same network, paired): \`unzip -q ios-device/cmux-mobile-$tag.ipa -d /tmp/mobile && xcrun devicectl device install app --device <udid> /tmp/mobile/Payload/CmuxMobileApp.app\`.
  Then trust the developer in Settings → General → VPN & Device Management if iOS asks.
- Simulator: \`ditto -x -k ios-simulator/cmux-mobile-$tag-sim.app.zip /tmp/cmux-mobile-sim && xcrun simctl install <udid> /tmp/cmux-mobile-sim/CmuxMobileApp.app && xcrun simctl launch <udid> $bundle_id\`.
- Mac: see \`cmux-mobile-host-macos-arm64/README.txt\`. \`./run-host.sh\` signs in (email code, or \`CMUX_MOBILE_STACK_EMAIL\`/\`CMUX_MOBILE_STACK_PASSWORD\`), registers the Mac and starts everything as you; \`./stop-host.sh\` stops it.
- Sign in on the phone with the **same account** as the Mac. The phone's email step accepts \`42\` for the dev test account; use the same account on the Mac (\`CMUX_MOBILE_STACK_EMAIL\`/\`CMUX_MOBILE_STACK_PASSWORD\`).

## Developer settings (Settings → Developer)

- **Mock data**: a local sample user with sample teams, Macs, chats and Feed; no network. Applies at the next launch ("Quit to apply").
- **Demo at next launch**: one scripted tour (live, workspaces, Chief, Feed and chat, terminal, team sidebar), run once.
- **Service** shows the backend host.

## Real vs mock

| Area | State |
| --- | --- |
| Sign-in (email code, \`42\` dev account) | Real, Stack dev project. Apple, Google and GitHub need a person at the provider sheet; Apple needs the Sign in with Apple capability, which this build does not carry. |
| Teams, devices, presence, Mac list | Real (\`cmux-mobile-api\` dev Worker). No Stack teams means the personal space "Personal". |
| Link to the Mac | Real: WireGuard (default; direct UDP or the Worker relay) or WebRTC (STUN only, no TURN yet). |
| Workspaces and tabs | Real, from the Mac's cmux-tui daemon. |
| Agent chat and Feed | Real, from acpmux on the Mac. The phone can deny or cancel; allow and question answers are refused by acpmux (\`permission.person_required\`). |
| Chief (Home) | Mock: \`conversation-*\` is not on cmux-mobile-host's allowlist. |
| Terminal | Demo screen only (Developer → Demo → Terminal); no terminal over the link yet. |
| Artifacts, diffs | Agent-session artifacts preview over the Mac's \`file\` service; terminal artifacts and diffs are sample data. |

## Known gaps (from \`cmux-next-ios/verify/*.md\`)

- The phone can only deny agent permissions, not allow or answer (needs a signed decision relay or a paired person key).
- WebRTC has no TURN: on a LAN it sometimes connects after one ICE timeout; away from home use WireGuard.
- No terminal over the link; new agent chats from the phone are not wired ("This chat hasn't started on the Mac yet").
- The Mac section's More menu (Reconnect, Unpair) is inert; no Mac picker UI.
- Chief over the link needs an allowlist and trust decision.
- Workspace activity times are first-seen times. Light mode and iOS 27 were not recorded in the live pass.
- The first dial right after registration can get a 401; the app retries with a fresh token.
EOF
  fi
  [[ ${#notes[@]} == 0 ]] || printf '\n## Build notes\n\n'
  for n in "${notes[@]+"${notes[@]}"}"; do echo "- $n"; done
  [[ -z "$installed" ]] || printf '\nInstalled on device %s at build time.\n' "$installed"
} > "$out/MANIFEST.md"

rm -rf "$work"
log "done: $out"
ls -R "$out" | head -40
