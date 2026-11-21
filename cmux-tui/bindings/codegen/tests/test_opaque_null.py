"""Explicit null on a non-nullable opaque-JSON field is a typed decode error.

Opaque JSON (``JsonValue`` and every ``opaque_json`` type) admits any JSON
document, null included, so the type alone never rejects null. Review finding
F1 on #41287: Java threw a NullPointerException on ``"first_tab": null`` in a
create-workspace reply and C++ kept the null. These tests pin the class in
every emitter that decodes field by field from generated code: each
non-nullable opaque field in the live schema gets its null guard.
"""

from __future__ import annotations

import copy
import unittest
from pathlib import Path, PurePosixPath
from typing import Any, Iterator, Mapping

from codegen import emit_cpp, emit_java
from codegen.ir import admits_json_null, load_ir, load_ir_document, mutable_document

from support import schema_document


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"


def _object_fields(
    path: str, expression: Mapping[str, Any]
) -> Iterator[tuple[str, str, Mapping[str, Any]]]:
    kind = expression.get("kind")
    if kind == "object":
        for name, field in expression["fields"].items():
            yield path, name, field
            yield from _object_fields(f"{path}.{name}", field["type"])
    elif kind == "tagged_union":
        for name, variant in expression["variants"].items():
            yield from _object_fields(f"{path}/{name}", variant)
    elif kind == "untagged_union":
        for index, variant in enumerate(expression["variants"]):
            yield from _object_fields(f"{path}/{index}", variant)
    elif kind == "array":
        yield from _object_fields(f"{path}[]", expression["items"])
    elif kind == "map":
        yield from _object_fields(f"{path}{{}}", expression["values"])


def _non_nullable_opaque_fields(
    document: Mapping[str, Any],
) -> list[tuple[str, str, Mapping[str, Any]]]:
    roots: list[tuple[str, Mapping[str, Any]]] = list(document["types"].items())
    for name, command in document["commands"].items():
        roots.append((f"{name}.request", command["request"]))
        roots.append((f"{name}.result", command["result"]))
    for name, event in document["events"].items():
        roots.append((name, event.get("payload") or {}))
    return [
        (owner, name, field)
        for root, expression in roots
        for owner, name, field in _object_fields(root, expression)
        if not field["nullable"] and admits_json_null(document["types"], field["type"])
    ]


def _schema_with_opaque_fields() -> dict[str, Any]:
    document = copy.deepcopy(schema_document())
    document["types"]["JsonValue"] = {
        "kind": "opaque_json",
        "reason": "Arbitrary JSON for the test.",
    }
    document["types"]["Workspace"]["fields"].update(
        {
            "extra": {
                "type": {"kind": "ref", "name": "JsonValue"},
                "presence": "optional",
                "nullable": False,
            },
            "spec": {
                "type": {"kind": "ref", "name": "JsonValue"},
                "presence": "required",
                "nullable": False,
            },
            "note": {
                "type": {"kind": "ref", "name": "JsonValue"},
                "presence": "optional",
                "nullable": True,
            },
        }
    )
    return document


class AdmitsJsonNullTests(unittest.TestCase):
    def test_opaque_json_and_aliases_admit_null_and_others_do_not(self) -> None:
        types = {
            "JsonValue": {"kind": "opaque_json", "reason": "any"},
            "Wrapped": {"kind": "alias", "target": {"kind": "ref", "name": "JsonValue"}},
            "Id": {"kind": "alias", "target": {"kind": "scalar", "name": "uint64"}},
            "Loop": {"kind": "alias", "target": {"kind": "ref", "name": "Loop"}},
        }
        admits = {
            "opaque": {"kind": "ref", "name": "JsonValue"},
            "alias of opaque": {"kind": "ref", "name": "Wrapped"},
            "inline opaque": {"kind": "opaque_json", "reason": "any"},
            "null literal": {"kind": "literal", "value": None},
            "union with opaque": {
                "kind": "untagged_union",
                "variants": [
                    {"kind": "scalar", "name": "string"},
                    {"kind": "ref", "name": "JsonValue"},
                ],
            },
        }
        rejects = {
            "scalar": {"kind": "scalar", "name": "string"},
            "alias of scalar": {"kind": "ref", "name": "Id"},
            "array of opaque": {
                "kind": "array",
                "items": {"kind": "ref", "name": "JsonValue"},
            },
            "self-referencing alias": {"kind": "ref", "name": "Loop"},
        }
        for label, expression in admits.items():
            with self.subTest(label):
                self.assertTrue(admits_json_null(types, expression))
        for label, expression in rejects.items():
            with self.subTest(label):
                self.assertFalse(admits_json_null(types, expression))

    def test_live_schema_has_the_finding_field(self) -> None:
        fields = _non_nullable_opaque_fields(mutable_document(load_ir(LIVE_SCHEMA)))
        self.assertIn(
            ("WorkspaceMutationResult", "first_tab"),
            {(owner, name) for owner, name, _ in fields},
        )


class JavaOpaqueNullTests(unittest.TestCase):
    def test_non_nullable_opaque_fields_reject_null_and_nullable_ones_keep_it(self) -> None:
        source = emit_java.emit(load_ir_document(_schema_with_opaque_fields()))[
            "Workspace.java"
        ]
        self.assertIn(
            'Wire.immutableJson(ProtocolSupport.nonNull(rawExtra, "Workspace.extra"))',
            source,
        )
        self.assertIn(
            'Wire.immutableJson(ProtocolSupport.nonNull(rawSpec, "Workspace.spec"))',
            source,
        )
        self.assertIn("rawNote == null ? null : Wire.immutableJson(rawNote)", source)
        self.assertNotIn("ProtocolSupport.nonNull(rawNote", source)
        self.assertNotIn("ProtocolSupport.nonNull(rawId", source)

    def test_every_live_non_nullable_opaque_field_is_guarded(self) -> None:
        ir = load_ir(LIVE_SCHEMA)
        joined = "\n".join(emit_java.emit(ir).values())
        self.assertIn("static Object nonNull(Object actual, String context)", joined)
        for owner, name, _ in _non_nullable_opaque_fields(mutable_document(ir)):
            with self.subTest(f"{owner}.{name}"):
                self.assertRegex(joined, rf'ProtocolSupport\.nonNull\(raw\w+, "[^"]*\.{name}"\)')


class CppOpaqueNullTests(unittest.TestCase):
    def _source(self, ir: Any) -> str:
        return emit_cpp.emit(ir)[PurePosixPath("src/raw/generated/protocol.cpp")]

    def test_non_nullable_opaque_fields_reject_null_and_nullable_ones_keep_it(self) -> None:
        source = self._source(load_ir_document(_schema_with_opaque_fields()))
        for member in ("extra", "spec"):
            with self.subTest(member):
                self.assertIn(
                    f"        if (field_{member}->is_null()) {{\n"
                    f"            return make_error(ErrorCode::decode, \"field '{member}' must not be null\");",
                    source,
                )
        self.assertIn("result.note = Field<", source)
        self.assertNotIn("field 'note' must not be null", source)
        self.assertNotIn("field 'id' must not be null", source)

    def test_every_live_non_nullable_opaque_field_is_guarded(self) -> None:
        ir = load_ir(LIVE_SCHEMA)
        source = self._source(ir)
        for owner, name, _ in _non_nullable_opaque_fields(mutable_document(ir)):
            with self.subTest(f"{owner}.{name}"):
                self.assertIn(f"field '{name}' must not be null", source)


if __name__ == "__main__":
    unittest.main()
