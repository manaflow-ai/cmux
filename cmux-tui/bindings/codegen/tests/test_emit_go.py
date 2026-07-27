from __future__ import annotations

import unittest

from codegen.emit_go import emit
from codegen.ir import load_ir_document

from support import schema_document


class GoEmitterTests(unittest.TestCase):
    def test_command_metadata_includes_field_compatibility_maps(self) -> None:
        document = schema_document()
        request = document["commands"]["list-workspaces"]["request"]
        request["fields"] = {
            "future": {
                "type": {"kind": "scalar", "name": "string"},
                "presence": "optional",
                "nullable": False,
                "since": 7,
            },
            "filtered": {
                "type": {"kind": "scalar", "name": "uint64"},
                "presence": "optional",
                "nullable": False,
                "capability": "filtered-workspaces",
            },
        }

        generated = emit(load_ir_document(document))
        metadata = generated["generated_metadata.go"]

        self.assertRegex(metadata, r"FieldSince\s+map\[string\]uint32")
        self.assertRegex(metadata, r"FieldCapabilities\s+map\[string\]string")
        self.assertIn(
            'FieldSince: map[string]uint32{"future": 7}',
            metadata,
        )
        self.assertIn(
            'FieldCapabilities: map[string]string{"filtered": "filtered-workspaces"}',
            metadata,
        )
        self.assertIn("cloneCommandMetadata(commandMetadata", metadata)

    def test_commands_without_field_gates_emit_nil_maps(self) -> None:
        generated = emit(load_ir_document(schema_document()))
        metadata = generated["generated_metadata.go"]

        self.assertIn("FieldSince: nil, FieldCapabilities: nil", metadata)


if __name__ == "__main__":
    unittest.main()
