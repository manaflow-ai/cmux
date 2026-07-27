from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from codegen.ir import load_ir, load_ir_document, mutable_document
from codegen.validate import ValidationError

from support import schema_document, write_schema


class IrTests(unittest.TestCase):
    def test_loads_immutable_sorted_ir_and_hashes_it(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            ir = load_ir(write_schema(Path(raw_directory)))

        self.assertEqual(ir.schema_version, 2)
        self.assertEqual(ir.mux_protocol, 10)
        self.assertEqual(len(ir.ir_sha256), 64)
        self.assertEqual(tuple(ir.types), tuple(sorted(ir.types)))
        self.assertEqual(ir.command("list-workspaces")["since"], 1)
        with self.assertRaises(TypeError):
            ir.types["Other"] = {}  # type: ignore[index]
        with self.assertRaises(KeyError):
            ir.event("missing")

    def test_hash_is_independent_of_json_object_key_order(self) -> None:
        first = schema_document()
        second = json.loads(json.dumps(first))
        second["types"] = dict(reversed(tuple(second["types"].items())))
        second["commands"] = dict(reversed(tuple(second["commands"].items())))
        self.assertEqual(
            load_ir_document(first).ir_sha256,
            load_ir_document(second).ir_sha256,
        )

    def test_accepts_legacy_root_and_array_entries(self) -> None:
        document = schema_document()
        document["mux_protocol"] = document.pop("protocol")["version"]
        command = document["commands"]["list-workspaces"]
        event = document["events"]["workspace-created"]
        document["commands"] = [
            {"wire_name": "list-workspaces", **command}
        ]
        document["events"] = [
            {"wire_name": "workspace-created", **event}
        ]
        ir = load_ir_document(document)
        self.assertEqual(tuple(ir.commands), ("list-workspaces",))
        self.assertEqual(ir.protocol["version"], 10)

    def test_rejects_mismatched_supplied_digest(self) -> None:
        document = schema_document()
        document["ir_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValidationError, "does not match derived"):
            load_ir_document(document)

    def test_mutable_copy_does_not_change_ir(self) -> None:
        ir = load_ir_document(schema_document())
        copy = mutable_document(ir)
        copy["types"]["Id"]["kind"] = "opaque_json"
        self.assertEqual(ir.type("Id")["kind"], "alias")


if __name__ == "__main__":
    unittest.main()
