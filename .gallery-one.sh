#!/usr/bin/env bash
set -euo pipefail
root="$GITHUB_WORKSPACE"
out="${FAST_CHECKS_OUT:?}"
mkdir -p "$out"
name="${CAPTURE_NAME:?}"
gallery="$RUNNER_TEMP/gallery-$name"
manifest="$RUNNER_TEMP/onboarding-$name.json"
variants="make-it-yours-preview,make-it-yours-preview-picked,make-it-yours-segmented,make-it-yours-form"
cd "$root/webviews"
bun install --frozen-lockfile
CMUX_GALLERY_OUT_DIR="$gallery" bun run gallery:build
bun scripts/gallery/manifest.ts --entries pages.onboarding --variants "$variants" --themes pair --widths narrow,normal --frame component --out "$manifest"
cd "$root/scripts/gallery-matrix"
bun install --frozen-lockfile
../ci/ensure-system-chrome.sh
CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest "$manifest" --gallery-dir "$gallery" --output-dir "$out" --engines chromium
preview=$(find "$out" -type f -name '*make-it-yours-preview*chromium*.png' | sort | head -1)
segmented=$(find "$out" -type f -name '*make-it-yours-segmented*chromium*.png' | sort | head -1)
test -n "$preview" && test -n "$segmented"
cp "$preview" "$out/onboarding-$name-preview.png"
cp "$segmented" "$out/onboarding-$name-segmented.png"
find "$out" -maxdepth 1 -type f -printf '%f %s\n' | sort
