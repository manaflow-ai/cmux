#!/bin/bash
set -euo pipefail

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}"
cd "$ROOT"

echo "ci_pre_xcodebuild: repository root is $ROOT"

if [ -f "vendor/bonsplit/Package.swift" ]; then
  echo "ci_pre_xcodebuild: vendor/bonsplit already present"
  exit 0
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ci_pre_xcodebuild: attempting submodule init for vendor/bonsplit"
  git submodule sync --recursive || true
  git submodule update --init --recursive vendor/bonsplit || true
fi

if [ ! -f "vendor/bonsplit/Package.swift" ]; then
  echo "ci_pre_xcodebuild: submodule not present, cloning fallback"
  rm -rf vendor/bonsplit
  mkdir -p vendor
  git clone --depth 1 https://github.com/manaflow-ai/bonsplit.git vendor/bonsplit

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    expected_sha="$(git ls-tree HEAD vendor/bonsplit | awk '{print $3}')"
    if [ -n "${expected_sha:-}" ]; then
      (
        cd vendor/bonsplit
        git fetch --depth 1 origin "$expected_sha" || true
        git checkout "$expected_sha" || true
      )
    fi
  fi
fi

if [ ! -f "vendor/bonsplit/Package.swift" ]; then
  echo "ci_pre_xcodebuild: missing vendor/bonsplit/Package.swift after recovery" >&2
  exit 1
fi

echo "ci_pre_xcodebuild: vendor/bonsplit is ready"
