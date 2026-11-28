#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDINGS_ROOT="$(cd "$ROOT/.." && pwd)"

python3 "$BINDINGS_ROOT/codegen/generate.py" --check --language java

rm -rf "$ROOT/build"
mkdir -p \
  "$ROOT/build/classes" \
  "$ROOT/build/test-classes" \
  "$ROOT/build/examples" \
  "$ROOT/build/consumer-test-classes"

SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(
  find "$ROOT/src" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror -d "$ROOT/build/classes" "${SOURCES[@]}"

TEST_SOURCES=()
while IFS= read -r source; do TEST_SOURCES+=("$source"); done < <(
  find "$ROOT/tests" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror \
  -cp "$ROOT/build/classes" \
  -d "$ROOT/build/test-classes" \
  "${TEST_SOURCES[@]}"

EXAMPLE_SOURCES=()
while IFS= read -r source; do EXAMPLE_SOURCES+=("$source"); done < <(
  find "$ROOT/examples" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror \
  -cp "$ROOT/build/classes" \
  -d "$ROOT/build/examples" \
  "${EXAMPLE_SOURCES[@]}"

jar --create --file "$ROOT/build/cmux-java-sdk.jar" -C "$ROOT/build/classes" .

CONSUMER_TEST_SOURCES=()
while IFS= read -r source; do CONSUMER_TEST_SOURCES+=("$source"); done < <(
  find "$ROOT/consumer-tests" -name '*.java' -type f | sort
)
javac --release 17 -Xlint:all -Werror -implicit:none \
  -cp "$ROOT/build/cmux-java-sdk.jar" \
  -d "$ROOT/build/consumer-test-classes" \
  "${CONSUMER_TEST_SOURCES[@]}"
