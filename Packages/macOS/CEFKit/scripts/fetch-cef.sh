#!/bin/zsh
# Fetches the CEF binary distribution this package builds against and stages
# the umbrella header the CCEF module map points at.
#
# Env overrides:
#   CEFKIT_CEF_SOURCE  Path to an existing extracted CEF distribution directory
#                      (e.g. a cef_binary_*_macosarm64 dir). Symlinked instead
#                      of downloading.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CEF_DIR="$ROOT_DIR/third_party/cef"
CEF_VERSION="146.0.5+g4db0d88+chromium-146.0.7680.65"
CEF_PLATFORM="macosarm64"
CEF_CHANNEL="_beta"
CEF_DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}${CEF_CHANNEL}"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_DIST}.tar.bz2"

mkdir -p "$CEF_DIR"

if [[ -n "${CEFKIT_CEF_SOURCE:-}" ]]; then
  if [[ ! -d "$CEFKIT_CEF_SOURCE/include/capi" ]]; then
    echo "CEFKIT_CEF_SOURCE does not look like a CEF distribution: $CEFKIT_CEF_SOURCE" >&2
    exit 1
  fi
  ln -sfn "${CEFKIT_CEF_SOURCE:A}" "$CEF_DIR/current"
else
  CEF_ARCHIVE="${CEF_DIR}/${CEF_DIST}.tar.bz2"
  if [[ ! -f "$CEF_ARCHIVE" ]]; then
    curl -fL -o "$CEF_ARCHIVE" "${CEF_URL//+/%2B}"
  fi
  EXPECTED_SHA1="$(curl -fsL "${CEF_URL//+/%2B}.sha1" | tr -d ' \n\r')"
  ACTUAL_SHA1="$(shasum -a 1 "$CEF_ARCHIVE" | awk '{print $1}')"
  if [[ "$EXPECTED_SHA1" != "$ACTUAL_SHA1" ]]; then
    echo "CEF archive SHA1 mismatch (expected $EXPECTED_SHA1, got $ACTUAL_SHA1)" >&2
    exit 1
  fi
  if [[ ! -d "$CEF_DIR/$CEF_DIST" ]]; then
    tar -xjf "$CEF_ARCHIVE" -C "$CEF_DIR"
  fi
  ln -sfn "$CEF_DIST" "$CEF_DIR/current"
fi

# CEF headers include each other via "include/..." paths. Exposing the dist's
# include tree as a symlink inside the CCEF target's include directory lets
# SwiftPM's normal header-search propagation resolve them with no unsafe
# flags.
ln -sfn "../../../third_party/cef/current/include" "$ROOT_DIR/Sources/CCEF/include/include"

echo "CEF ready at $CEF_DIR/current"
