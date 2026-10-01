from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


BINDINGS = Path(__file__).resolve().parents[2]
LIVE_SCHEMA = BINDINGS.parent / "spec" / "sdk-schema.json"

# Each SDK's own tests pin the generated command count. A command added to
# the schema must bump every pin in the same change; this names them all.
PINS = {
    "go/raw/client_test.go": r"len\(commands\) != (\d+) \{",
    "typescript/test/generated.test.ts": r"Object\.keys\(COMMAND_METADATA\)\.length, (\d+)\)",
    "java/tests/com/cmux/raw/GeneratedCoverageTest.java": r"Commands\.ALL\.size\(\) == (\d+),",
    "cpp/tests/test_generated.cpp": r"kExpectedRawCommandCount = (\d+)U;",
    "zig/src/raw.zig": r"@as\(usize, (\d+)\), protocol\.command_count",
    "zig/examples/watch.zig": r"@as\(usize, (\d+)\),\s*cmux\.raw\.protocol\.command_count",
}


class SdkInventoryPinTests(unittest.TestCase):
    def test_every_sdk_pins_the_schema_command_count(self) -> None:
        expected = len(json.loads(LIVE_SCHEMA.read_text())["commands"])
        stale = []
        for path, pattern in PINS.items():
            match = re.search(pattern, (BINDINGS / path).read_text())
            self.assertIsNotNone(match, f"{path}: command count pin not found")
            if int(match.group(1)) != expected:
                stale.append(f"{path}: {match.group(1)}")
        self.assertEqual(stale, [], f"set these command count pins to {expected}")


if __name__ == "__main__":
    unittest.main()
