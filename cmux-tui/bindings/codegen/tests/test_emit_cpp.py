from __future__ import annotations

import copy
import unittest
from pathlib import PurePosixPath

from codegen.emit_cpp import emit
from codegen.ir import load_ir_document

from support import schema_document


class CppEmitterTests(unittest.TestCase):
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
            PurePosixPath("include/cmux/generated/commands.hpp")
        ]
        source = generated[PurePosixPath("src/generated/protocol.cpp")]

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
