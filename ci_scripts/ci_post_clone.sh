#!/bin/bash
set -euo pipefail

echo "=== ci_post_clone.sh ==="

# Initialize submodules (needed for vendor/bonsplit SPM package)
echo "Initializing submodules..."
git submodule update --init --recursive

# Get ghostty submodule SHA
GHOSTTY_SHA=$(git -C "$CI_PRIMARY_REPOSITORY_PATH/ghostty" rev-parse HEAD)
echo "Ghostty SHA: $GHOSTTY_SHA"

# Download pre-built xcframework from manaflow-ai/ghostty releases
TAG="xcframework-$GHOSTTY_SHA"
URL="https://github.com/manaflow-ai/ghostty/releases/download/$TAG/GhosttyKit.xcframework.tar.gz"

echo "Downloading xcframework from $URL"

MAX_RETRIES=30
RETRY_DELAY=20

for i in $(seq 1 $MAX_RETRIES); do
  if curl -fSL -o "$CI_PRIMARY_REPOSITORY_PATH/GhosttyKit.xcframework.tar.gz" "$URL"; then
    echo "Download succeeded on attempt $i"
    break
  fi
  if [ "$i" -eq "$MAX_RETRIES" ]; then
    echo "Failed to download xcframework after $MAX_RETRIES attempts" >&2
    exit 1
  fi
  echo "Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
  sleep $RETRY_DELAY
done

# Extract xcframework to project root
echo "Extracting xcframework..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
tar xzf GhosttyKit.xcframework.tar.gz
rm GhosttyKit.xcframework.tar.gz
test -d GhosttyKit.xcframework
echo "GhosttyKit.xcframework extracted successfully"

# Download Metal toolchain (required for shader compilation)
echo "Downloading Metal toolchain..."
xcodebuild -downloadComponent MetalToolchain

echo "=== ci_post_clone.sh done ==="
