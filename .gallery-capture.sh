#!/usr/bin/env bash
set -euo pipefail
root="$GITHUB_WORKSPACE"
out="${FAST_CHECKS_OUT:?}"
mkdir -p "$out"
head_gallery="$RUNNER_TEMP/gallery-head"
base_gallery="$RUNNER_TEMP/gallery-base"
head_manifest="$RUNNER_TEMP/onboarding-head.json"
base_manifest="$RUNNER_TEMP/onboarding-base.json"
variants="make-it-yours-preview,make-it-yours-preview-picked,make-it-yours-segmented,make-it-yours-form"
cd "$root/webviews"
bun install --frozen-lockfile
CMUX_GALLERY_OUT_DIR="$head_gallery" bun run gallery:build
bun scripts/gallery/manifest.ts --entries pages.onboarding --variants "$variants" --themes pair --widths narrow,normal --frame component --out "$head_manifest"
git fetch --no-tags origin feat-cmux-next
git worktree add --detach "$RUNNER_TEMP/base-cmux" origin/feat-cmux-next
cd "$RUNNER_TEMP/base-cmux/webviews"
bun install --frozen-lockfile
CMUX_GALLERY_OUT_DIR="$base_gallery" bun run gallery:build
bun scripts/gallery/manifest.ts --entries pages.onboarding --variants "$variants" --themes pair --widths narrow,normal --frame component --out "$base_manifest"
cd "$root/scripts/gallery-matrix"
bun install --frozen-lockfile
../ci/ensure-system-chrome.sh
CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest "$base_manifest" --gallery-dir "$base_gallery" --output-dir "$out/before" --engines chromium
CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest "$head_manifest" --gallery-dir "$head_gallery" --output-dir "$out/after" --engines chromium
find "$out" -type f -name '*.png' -print | sort
before_preview=$(find "$out/before" -type f -name '*make-it-yours-preview*chromium*.png' | sort | head -1)
after_preview=$(find "$out/after" -type f -name '*make-it-yours-preview*chromium*.png' | sort | head -1)
before_segmented=$(find "$out/before" -type f -name '*make-it-yours-segmented*chromium*.png' | sort | head -1)
after_segmented=$(find "$out/after" -type f -name '*make-it-yours-segmented*chromium*.png' | sort | head -1)
for pair in before_preview after_preview before_segmented after_segmented; do test -n "${!pair}" || { echo "missing $pair" >&2; exit 1; }; done
cp "$before_preview" "$out/onboarding-before-preview.png"
cp "$after_preview" "$out/onboarding-after-preview.png"
cp "$before_segmented" "$out/onboarding-before-segmented.png"
cp "$after_segmented" "$out/onboarding-after-segmented.png"
