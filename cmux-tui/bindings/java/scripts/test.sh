#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

CLASSPATH="$ROOT/build/classes:$ROOT/build/test-classes"
for test_class in \
  com.cmux.raw.CodecTest \
  com.cmux.raw.SocketDiscoveryTest \
  com.cmux.raw.GeneratedCoverageTest \
  com.cmux.raw.GeneratedModelTest \
  com.cmux.raw.StreamModeTest \
  com.cmux.raw.LifecycleTest \
  com.cmux.raw.ErgonomicsTest \
  com.cmux.internal.UnixTransportTest \
  com.cmux.ResourceApiTest \
  com.cmux.BrowserPointerFrameTest
do
  java -ea -cp "$CLASSPATH" "$test_class"
done

java -ea \
  -cp "$ROOT/build/cmux-java-sdk.jar:$ROOT/build/consumer-test-classes" \
  com.cmux.consumer.ExternalJarConsumerTest
