#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

CLASSPATH="$ROOT/build/classes:$ROOT/build/test-classes"
for test_class in \
  com.cmux.CodecTest \
  com.cmux.SocketDiscoveryTest \
  com.cmux.GeneratedCoverageTest \
  com.cmux.GeneratedModelTest \
  com.cmux.StreamModeTest \
  com.cmux.LifecycleTest \
  com.cmux.ErgonomicsTest
do
  java -ea -cp "$CLASSPATH" "$test_class"
done

java -ea \
  -cp "$ROOT/build/cmux-java-sdk.jar:$ROOT/build/consumer-test-classes" \
  com.cmux.consumer.ExternalJarConsumerTest
