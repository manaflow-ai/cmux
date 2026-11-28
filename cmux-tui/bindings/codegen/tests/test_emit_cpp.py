from __future__ import annotations

import copy
import unittest
from pathlib import PurePosixPath

from codegen.emit_cpp import emit
from codegen.ir import load_ir_document

from support import schema_document


class CppEmitterTests(unittest.TestCase):
    def test_predefined_macro_enum_values_use_safe_identifiers(self) -> None:
        document = copy.deepcopy(schema_document())
        document["types"]["Transport"] = {
            "kind": "enum",
            "values": ["unix", "ws"],
        }

        generated = emit(load_ir_document(document))
        header = generated[
            PurePosixPath("include/cmux/raw/generated/models.hpp")
        ]
        source = generated[PurePosixPath("src/raw/generated/protocol.cpp")]

        self.assertIn("enum class Transport {\n    unix_,\n    ws,\n};", header)
        self.assertIn(
            'case Transport::unix_: return Json(std::string("unix"));',
            source,
        )
        self.assertIn(
            'if (value == Json(std::string("unix"))) return Transport::unix_;',
            source,
        )

    def test_command_metadata_includes_field_compatibility_requirements(self) -> None:
        document = copy.deepcopy(schema_document())
        document["commands"]["list-workspaces"]["request"] = {
            "kind": "object",
            "fields": {
                "filter": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": False,
                    "since": 3,
                    "capability": "workspace-filter-v1",
                }
            },
            "additional_properties": False,
        }

        generated = emit(load_ir_document(document))
        header = generated[
            PurePosixPath("include/cmux/raw/generated/commands.hpp")
        ]
        source = generated[PurePosixPath("src/raw/generated/protocol.cpp")]

        self.assertIn("struct CommandFieldRequirement {", header)
        self.assertIn(
            "std::span<const CommandFieldRequirement> field_requirements;",
            header,
        )
        self.assertIn(
            '{"filter", 3U, "workspace-filter-v1"},',
            source,
        )
        self.assertIn(
            "std::span<const CommandFieldRequirement>(kCommand0FieldRequirements)",
            source,
        )


if __name__ == "__main__":
    unittest.main()
