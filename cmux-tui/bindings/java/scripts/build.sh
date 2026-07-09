#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rm -rf out
mkdir -p out
javac --release 17 -d out $(find src tests -name '*.java' | sort)
