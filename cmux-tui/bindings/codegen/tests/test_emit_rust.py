from __future__ import annotations

import os
import re
import unittest
from collections.abc import Mapping
from pathlib import Path
from unittest import mock

from codegen.emit_rust import emit
from codegen.ir import load_ir, load_ir_document

from support import schema_document


STRICT_OPTIONAL_NON_NULL = (
    'deserialize_with = "crate::presence::deserialize_optional_non_null"'
)


def count_optional_non_null_fields(value: object) -> int:
    if isinstance(value, Mapping):
        count = int(
            value.get("presence") == "optional"
            and value.get("nullable") is False
        )
        return count + sum(
            count_optional_non_null_fields(item) for item in value.values()
        )
    if isinstance(value, (tuple, list)):
        return sum(count_optional_non_null_fields(item) for item in value)
    return 0


class RustEmitterTests(unittest.TestCase):
    def test_generated_layout_is_owned_and_does_not_require_rustfmt(self) -> None:
        ir = load_ir_document(schema_document())

        with mock.patch.dict(os.environ, {"PATH": ""}):
            first = emit(ir)
            second = emit(ir)

        self.assertEqual(first, second)
        self.assertEqual(
            set(first),
            {"commands.rs", "events.rs", "metadata.rs", "mod.rs", "types.rs"},
        )
        for path, source in first.items():
            with self.subTest(path=path):
                self.assertIsInstance(source, str)
                if path != "mod.rs":
                    self.assertIn(
                        "#[rustfmt::skip]\n",
                        source,
                        "complex generated items must keep emitter-owned layout",
                    )
                self.assertNotIn("#![rustfmt::skip]", source)

    def test_every_optional_non_null_field_uses_strict_deserialization(self) -> None:
        schema = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"
        ir = load_ir(schema)
        generated = emit(ir)
        expected = count_optional_non_null_fields(ir.document)
        actual = 0

        for path in ("types.rs", "commands.rs", "events.rs"):
            source = generated[path]
            self.assertIsInstance(source, str)
            if path == "events.rs":
                source = source.split("pub struct UnknownEvent", 1)[0]
            lines = source.splitlines()
            option_fields = [
                index
                for index, line in enumerate(lines)
                if re.match(r"^\s+(?:pub )?\w+: Option<", line)
            ]
            strict_fields = [
                index
                for index, line in enumerate(lines)
                if STRICT_OPTIONAL_NON_NULL in line
            ]

            self.assertEqual(
                len(strict_fields),
                len(option_fields),
                f"{path} has an Option field without strict null handling",
            )
            for index in option_fields:
                self.assertIn(
                    STRICT_OPTIONAL_NON_NULL,
                    lines[index - 1],
                    f"{path}:{index + 1} accepts explicit null",
                )
            actual += len(strict_fields)

        self.assertGreater(expected, 0)
        self.assertEqual(actual, expected)
        self.assertIn("pub paste: Option<bool>", generated["commands.rs"])


if __name__ == "__main__":
    unittest.main()
