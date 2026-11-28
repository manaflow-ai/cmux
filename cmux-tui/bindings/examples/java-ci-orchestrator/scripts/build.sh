#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDINGS_ROOT="$(cd "$ROOT/../.." && pwd)"
SDK_ROOT="$BINDINGS_ROOT/java"

if [[ -z "${CMUX_JAVA_SDK_JAR:-}" ]]; then
  "$SDK_ROOT/scripts/build.sh"
  SDK_JAR="$SDK_ROOT/build/cmux-java-sdk.jar"
else
  SDK_JAR="$CMUX_JAVA_SDK_JAR"
fi

if [[ ! -f "$SDK_JAR" ]]; then
  echo "Java SDK jar not found: $SDK_JAR" >&2
  exit 1
fi

rm -rf "$ROOT/build"
mkdir -p "$ROOT/build/classes" "$ROOT/build/test-classes"

SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$ROOT/src" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror \
  -cp "$SDK_JAR" \
  -d "$ROOT/build/classes" \
  "${SOURCES[@]}"

TEST_SOURCES=()
while IFS= read -r source; do TEST_SOURCES+=("$source"); done < <(
  find "$ROOT/tests" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror \
  -cp "$SDK_JAR:$ROOT/build/classes" \
  -d "$ROOT/build/test-classes" \
  "${TEST_SOURCES[@]}"

jar --create \
  --file "$ROOT/build/java-ci-orchestrator.jar" \
  --main-class com.cmux.examples.ci.CiOrchestrator \
  -C "$ROOT/build/classes" .
