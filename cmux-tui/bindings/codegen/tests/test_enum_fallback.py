"""Enum `fallback`: a decoder maps a string value it does not know to the fallback.

`SizeDeviceKind` uses it so a device kind added after an SDK was built (for
example `linux` and `windows`) decodes as `unknown` instead of failing the
whole `size-state`. Encoding stays strict.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from codegen.validate import ValidationError, validate_document

from support import schema_document

BINDINGS = Path(__file__).resolve().parents[2]
SPEC = BINDINGS.parent / "spec" / "sdk-schema.json"


def _with_enum(**extra: object) -> dict:
    document = schema_document()
    document["types"]["Kind"] = {"kind": "enum", "values": ["a", "b", "unknown"], **extra}
    return document


class EnumFallbackValidationTests(unittest.TestCase):
    def test_accepts_a_fallback_that_is_one_of_the_values(self) -> None:
        validate_document(_with_enum(fallback="unknown"))

    def test_rejects_a_fallback_outside_the_values(self) -> None:
        with self.assertRaisesRegex(ValidationError, "fallback"):
            validate_document(_with_enum(fallback="other"))

    def test_rejects_a_fallback_on_a_non_string_enum(self) -> None:
        document = schema_document()
        document["types"]["Kind"] = {"kind": "enum", "values": [1, 2], "fallback": 1}
        with self.assertRaisesRegex(ValidationError, "fallback"):
            validate_document(document)


class SizeDeviceKindFallbackTests(unittest.TestCase):
    def test_spec_names_linux_and_windows_and_falls_back_to_unknown(self) -> None:
        kind = json.loads(SPEC.read_text())["types"]["SizeDeviceKind"]
        self.assertEqual(
            kind["values"],
            ["mac", "iphone", "ipad", "tui", "browser", "linux", "windows", "unknown"],
        )
        self.assertEqual(kind["fallback"], "unknown")

    def _read(self, relative: str) -> str:
        return (BINDINGS / relative).read_text()

    def test_rust_marks_the_fallback_variant_serde_other(self) -> None:
        source = self._read("rust/src/generated/types.rs")
        enum = re.search(r"pub enum SizeDeviceKind \{.*?\n\}", source, re.S).group(0)
        self.assertIn('#[serde(rename = "unknown", other)]\n    Unknown,', enum)
        self.assertNotIn("other", re.sub(r"#\[serde\(rename = \"unknown\", other\)\]", "", enum))

    def test_go_decodes_unknown_strings_to_the_fallback(self) -> None:
        source = self._read("go/raw/generated_types.go")
        start = source.index("func (value *SizeDeviceKind) UnmarshalJSON")
        body = source[start : source.index("\n}\n", start)]
        self.assertIn("candidate = SizeDeviceKindUnknown", body)

    def test_java_decodes_unknown_strings_to_the_fallback(self) -> None:
        source = self._read("java/src/com/cmux/raw/SizeDeviceKind.java")
        self.assertIn("if (value instanceof String) {\n            return UNKNOWN;", source)

    def test_cpp_decodes_unknown_strings_to_the_fallback(self) -> None:
        source = self._read("cpp/src/raw/generated/protocol.cpp")
        start = source.index("Result<SizeDeviceKind> Codec<SizeDeviceKind>::decode")
        body = source[start : source.index("\n}\n", start)]
        self.assertIn("if (value.is_string()) return SizeDeviceKind::unknown;", body)

    def test_zig_decodes_unknown_strings_to_the_fallback(self) -> None:
        source = self._read("zig/src/raw/generated/protocol.zig")
        start = source.index("pub const SizeDeviceKind = enum {")
        body = source[start : source.index("\n};\n", start)]
        self.assertIn("return .unknown;\n    }", body)
        self.assertNotIn("error.UnknownEnumValue", body)

    def test_other_enums_stay_closed(self) -> None:
        source = self._read("rust/src/generated/types.rs")
        enum = re.search(r"pub enum SizeMode \{.*?\n\}", source, re.S).group(0)
        self.assertNotIn("other", enum)


if __name__ == "__main__":
    unittest.main()
