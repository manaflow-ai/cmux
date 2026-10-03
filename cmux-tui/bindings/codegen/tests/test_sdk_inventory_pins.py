from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


BINDINGS = Path(__file__).resolve().parents[2]
LIVE_SCHEMA = BINDINGS.parent / "spec" / "sdk-schema.json"

# Each SDK's own tests pin the generated command and event counts. A schema
# change that adds one must bump every pin in the same change; this names
# them all.
COMMAND_PINS = {
    "python/tests/test_protocol.py": r"len\(COMMANDS\), (\d+)\)",
    "go/raw/client_test.go": r"len\(commands\) != (\d+) \{",
    "typescript/test/generated.test.ts": r"Object\.keys\(COMMAND_METADATA\)\.length, (\d+)\)",
    "java/tests/com/cmux/raw/GeneratedCoverageTest.java": r"Commands\.ALL\.size\(\) == (\d+),",
    "cpp/tests/test_generated.cpp": r"kExpectedRawCommandCount = (\d+)U;",
    "zig/src/raw.zig": r"@as\(usize, (\d+)\), protocol\.command_count",
    "zig/examples/watch.zig": r"@as\(usize, (\d+)\),\s*cmux\.raw\.protocol\.command_count",
}
EVENT_PINS = {
    "go/raw/client_test.go": r"len\(events\) != (\d+) \{",
    "typescript/test/generated.test.ts": r"Object\.keys\(EVENT_METADATA\)\.length, (\d+)\)",
    "java/tests/com/cmux/raw/GeneratedCoverageTest.java": r"Events\.ALL\.size\(\) == (\d+),",
    "cpp/tests/test_generated.cpp": r"CHECK_EQ\(events\.size\(\), (\d+)U\);",
    "zig/src/raw.zig": r"@as\(usize, (\d+)\), protocol\.event_count",
    "zig/examples/watch.zig": r"@as\(usize, (\d+)\),\s*cmux\.raw\.protocol\.event_count",
}
EMITTED_EVENT_PINS = {
    "typescript/test/generated.test.ts": r"assert\.equal\(emitted\.length, (\d+)\);",
}


def stale_pins(pins: dict[str, str], expected: int) -> list[str]:
    stale = []
    for path, pattern in pins.items():
        matches = re.findall(pattern, (BINDINGS / path).read_text())
        if not matches:
            stale.append(f"{path}: pin not found")
        stale += [f"{path}: {value}" for value in matches if int(value) != expected]
    return stale


class SdkInventoryPinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads(LIVE_SCHEMA.read_text())

    def test_every_sdk_pins_the_schema_command_count(self) -> None:
        expected = len(self.schema["commands"])
        self.assertEqual(stale_pins(COMMAND_PINS, expected), [], f"set these command count pins to {expected}")

    def test_every_sdk_pins_the_schema_event_count(self) -> None:
        expected = len(self.schema["events"])
        self.assertEqual(stale_pins(EVENT_PINS, expected), [], f"set these event count pins to {expected}")

    def test_every_sdk_pins_the_schema_emitted_event_count(self) -> None:
        expected = sum(1 for event in self.schema["events"].values() if event["emission"] == "emitted")
        self.assertEqual(
            stale_pins(EMITTED_EVENT_PINS, expected), [], f"set these emitted event count pins to {expected}"
        )


if __name__ == "__main__":
    unittest.main()
