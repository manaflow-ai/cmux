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
EXT_DIR="${CEFKIT_EXTENSIONS_DIR:-$ROOT_DIR/third_party/extensions}"
CURL_BIN="${CEFKIT_CURL_BIN:-curl}"
UNZIP_BIN="${CEFKIT_UNZIP_BIN:-unzip}"
mkdir -p "$EXT_DIR"

# uBlock Origin Lite (MV3), not classic uBlock Origin (MV2): MV2's
# webRequest blocking never fires for Alloy-style embedded browsers (only
# for Chrome-style windows) and unpacked MV2 is disabled until the user
# turns on developer mode. uBOL's declarativeNetRequest rules are enforced
# by the network service and block in embedded panes out of the box.
UBOL_VERSION="2026.711.25"
UBOL_URL="https://github.com/uBlockOrigin/uBOL-home/releases/download/${UBOL_VERSION}/uBOLite_${UBOL_VERSION}.chromium.zip"
UBOL_SHA256="720b12cbc52b480599cd7becca99efce5babea9b52af4373de6bdb2d935215ee"

BITWARDEN_VERSION="2026.6.1"
BITWARDEN_URL="https://github.com/bitwarden/clients/releases/download/browser-v${BITWARDEN_VERSION}/dist-chrome-${BITWARDEN_VERSION}.zip"
BITWARDEN_SHA256="fcd29c5971d9b218ad9159717a19c38cca5150f2a0aa909ddf805bd7695d097e"

content_digest() {
  local root="$1" file relative
  local -a files
  files=("$root"/**/*(DN.))
  {
    for file in "${files[@]}"; do
      relative="${file#$root/}"
      [[ "$relative" == ".fetched-version" || "$relative" == ".fetched-content-sha256" ]] && continue
      printf '%s\0%s\0' "$relative" "$(shasum -a 256 "$file" | awk '{print $1}')"
    done
  } | shasum -a 256 | awk '{print $1}'
}

fetch_zip() {
  local name="$1" version="$2" url="$3" sha256="$4" inner_dir="$5"
  local dest="$EXT_DIR/$name"
  local stamp="$dest/.fetched-version"
  local content_stamp="$dest/.fetched-content-sha256"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$version" && -f "$dest/manifest.json" && -f "$content_stamp" ]]; then
    if [[ "$(cat "$content_stamp")" == "$(content_digest "$dest")" ]]; then
      echo "fetch-extensions: $name $version already fetched and verified"
      return
    fi
    echo "fetch-extensions: $name $version cached content changed; fetching a verified copy" >&2
  fi
  local tmp
  tmp="$(mktemp -d)"
  echo "fetch-extensions: downloading $name $version"
  "$CURL_BIN" -fsSL -o "$tmp/ext.zip" "$url"
  if ! printf '%s  %s\n' "$sha256" "$tmp/ext.zip" | shasum -a 256 -c - >/dev/null; then
    echo "fetch-extensions: $name $version SHA-256 mismatch" >&2
    rm -rf "$tmp"
    exit 1
  fi
  "$UNZIP_BIN" -q "$tmp/ext.zip" -d "$tmp/unpacked"
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
  content_digest "$dest" > "$content_stamp"
  rm -rf "$tmp"
  echo "fetch-extensions: $name $version -> $dest"
}

fetch_zip "ublock-origin-lite" "$UBOL_VERSION" "$UBOL_URL" "$UBOL_SHA256" ""
fetch_zip "bitwarden" "$BITWARDEN_VERSION" "$BITWARDEN_URL" "$BITWARDEN_SHA256" ""

echo "fetch-extensions: done ($EXT_DIR)"
