from __future__ import annotations

import unittest

from codegen.emit_zig import render
from codegen.ir import load_ir_document

from support import schema_document


class ZigEmitterTests(unittest.TestCase):
    def test_generated_calls_include_command_and_field_requirements(self) -> None:
        document = schema_document()
        command = document["commands"]["list-workspaces"]
        command["since"] = 7
        command["capability"] = "workspace-registry-v1"
        command["request"] = {
            "kind": "object",
            "fields": {
                "surface": {
                    "type": {"kind": "ref", "name": "Id"},
                    "presence": "optional",
                    "nullable": True,
                    "default": None,
                    "since": 9,
                    "capability": "surface-filter-v1",
                }
            },
            "additional_properties": False,
        }

        source = render(load_ir_document(document))["protocol.zig"]

        self.assertIn(
            """return client.callTyped(
        ListWorkspacesResult,
        .{
            .name = "list-workspaces",
            .authority = "control",
            .since = 7,
            .capability = "workspace-registry-v1",
            .fields = &.{
                .{ .name = "surface", .since = 9, .capability = "surface-filter-v1" },
            },
        },
        request,
    );""",
            source,
        )

    def test_generated_stream_calls_use_the_same_requirement_path(self) -> None:
        document = schema_document()
        command = document["commands"]["list-workspaces"]
        command["request"] = {
            "kind": "object",
            "fields": {
                "mode": {
                    "type": {"kind": "enum", "values": ["coarse"]},
                    "presence": "optional",
                    "nullable": True,
                    "default": "coarse",
                }
            },
            "additional_properties": False,
        }
        command["stream"] = {
            "kind": "subscribe",
            "event_names": ["workspace-created"],
            "mode_field": "mode",
            "modes": {"coarse": ["workspace-created"]},
            "ordering": "Events preserve order.",
            "terminal_event": None,
        }

        source = render(load_ir_document(document))["protocol.zig"]

        self.assertIn(
            """return client.openStream(
        .{
            .name = "list-workspaces",
            .authority = "control",
            .since = 1,
            .capability = null,
        },
        request,
        null,
    );""",
            source,
        )

    def test_event_wire_name_covers_known_and_unknown_events(self) -> None:
        source = render(load_ir_document(schema_document()))["protocol.zig"]

        self.assertIn(
            """pub fn eventWireName(event: Event) []const u8 {
    return switch (event) {
        .workspace_created => "workspace-created",
        .unknown => |unknown| unknown.name,
    };
}""",
            source,
        )


if __name__ == "__main__":
    unittest.main()
