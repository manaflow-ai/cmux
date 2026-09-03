from __future__ import annotations

import copy
import unittest
from pathlib import PurePosixPath

from codegen.emit_cpp import emit
from codegen.ir import load_ir_document

from support import schema_document


class CppEmitterTests(unittest.TestCase):
    def test_conditional_follow_stream_preserves_unary_and_stream_methods(self) -> None:
        document = copy.deepcopy(schema_document())
        document["types"]["StatsResult"] = {"kind": "object", "fields": {}, "additional_properties": False}
        document["commands"]["machine-stats"] = {
            "authority": "control", "since": 10, "capability": "stats-v1",
            "request": {"kind": "object", "fields": {"follow": {"type": {"kind": "scalar", "name": "boolean"}, "presence": "optional", "nullable": False, "default": False}}, "additional_properties": False},
            "result": {"kind": "ref", "name": "StatsResult"},
            "stream": {"kind": "subscribe", "event_names": ["workspace-created"], "mode_field": "follow", "modes": {"false": [], "true": ["workspace-created"]}, "ordering": "response then events", "terminal_event": None},
            "constraints": [],
        }
        generated = emit(load_ir_document(document))
        header = generated[PurePosixPath("include/cmux/raw/generated/commands.hpp")]
        self.assertIn("Result<StatsResult> machine_stats(", header)
        self.assertIn("Result<EventStream> machine_stats_follow(", header)

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
