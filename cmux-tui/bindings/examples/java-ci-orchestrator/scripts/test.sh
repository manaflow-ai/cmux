#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDINGS_ROOT="$(cd "$ROOT/../.." && pwd)"
SDK_ROOT="$BINDINGS_ROOT/java"

"$ROOT/scripts/build.sh"

SDK_JAR="${CMUX_JAVA_SDK_JAR:-$SDK_ROOT/build/cmux-java-sdk.jar}"
java -ea \
  -cp "$SDK_JAR:$ROOT/build/classes:$ROOT/build/test-classes" \
  com.cmux.examples.ci.CiOrchestratorIntegrationTest
