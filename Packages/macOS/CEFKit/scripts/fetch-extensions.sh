#!/bin/zsh
# Fetches the preinstalled Chrome extensions for CEF dev builds into
# third_party/extensions (gitignored, like the CEF distribution). The dev
# bundling step (scripts/copy-cef-runtime-dev.sh at the repo root) copies
# every fetched extension into the app's Resources/CEFExtensions, where the
# CEF debug browser and CEF panes load them via --load-extension.
#
# Sources are the projects' own GitHub release artifacts (unpacked-ready
# zips), not Chrome Web Store CRXs. Versions are pinned; bump deliberately.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$ROOT_DIR/third_party/extensions"
mkdir -p "$EXT_DIR"

# uBlock Origin Lite (MV3), not classic uBlock Origin (MV2): MV2's
# webRequest blocking never fires for Alloy-style embedded browsers (only
# for Chrome-style windows) and unpacked MV2 is disabled until the user
# turns on developer mode. uBOL's declarativeNetRequest rules are enforced
# by the network service and block in embedded panes out of the box.
UBOL_VERSION="2026.711.25"
UBOL_URL="https://github.com/uBlockOrigin/uBOL-home/releases/download/${UBOL_VERSION}/uBOLite_${UBOL_VERSION}.chromium.zip"

BITWARDEN_VERSION="2026.6.1"
BITWARDEN_URL="https://github.com/bitwarden/clients/releases/download/browser-v${BITWARDEN_VERSION}/dist-chrome-${BITWARDEN_VERSION}.zip"

fetch_zip() {
  local name="$1" version="$2" url="$3" inner_dir="$4"
  local dest="$EXT_DIR/$name"
  local stamp="$dest/.fetched-version"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$version" && -f "$dest/manifest.json" ]]; then
    echo "fetch-extensions: $name $version already fetched"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  echo "fetch-extensions: downloading $name $version"
  curl -fsSL -o "$tmp/ext.zip" "$url"
  unzip -q "$tmp/ext.zip" -d "$tmp/unpacked"
  local src="$tmp/unpacked"
  if [[ -n "$inner_dir" ]]; then
    src="$tmp/unpacked/$inner_dir"
  fi
  if [[ ! -f "$src/manifest.json" ]]; then
    echo "fetch-extensions: $name archive layout unexpected (no manifest.json at ${inner_dir:-root})" >&2
    find "$tmp/unpacked" -maxdepth 2 -name manifest.json >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$dest"
  mkdir -p "$EXT_DIR"
  ditto "$src" "$dest"
  printf '%s' "$version" > "$stamp"
  rm -rf "$tmp"
  echo "fetch-extensions: $name $version -> $dest"
}

fetch_zip "ublock-origin-lite" "$UBOL_VERSION" "$UBOL_URL" ""
fetch_zip "bitwarden" "$BITWARDEN_VERSION" "$BITWARDEN_URL" ""

echo "fetch-extensions: done ($EXT_DIR)"
