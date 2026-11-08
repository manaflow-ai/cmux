from __future__ import annotations

import json
import unittest
from collections.abc import Mapping
from pathlib import Path

from codegen.emit_zig import ZigEmitter, render
from codegen.ir import load_ir, load_ir_document

from support import schema_document


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

    def test_struct_marker_only_lists_optional_non_null_fields(self) -> None:
        document = schema_document()
        document["types"]["Workspace"]["fields"].update(
            {
                "optional_nonnull": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": False,
                },
                "optional_nullable": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "optional",
                    "nullable": True,
                },
                "required_nullable": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "required",
                    "nullable": True,
                },
            }
        )

        generated = render(load_ir_document(document))
        source = generated["protocol.zig"]

        self.assertIn(
            """pub const Workspace = struct {
    id: Id,
    optional_nonnull: ?[]const u8 = null,
    optional_nullable: wire.Field([]const u8) = .absent,
    required_nullable: wire.Nullable([]const u8),

    pub const cmux_wire_optional_nonnull_fields = [_][]const u8{
        "optional_nonnull",
    };
};""",
            source,
        )
        self.assertIn(
            "expectExplicitNullRejected(protocol.Workspace, "
            '"optional_nonnull");',
            generated["presence_test.zig"],
        )

    def test_every_optional_non_null_field_uses_shared_strict_decode_path(
        self,
    ) -> None:
        schema = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"
        ir = load_ir(schema)
        emitter = ZigEmitter(ir)
        protocol = emitter.render()
        presence_test = emitter.render_presence_test()
        expected = count_optional_non_null_fields(ir.document)

        self.assertGreater(expected, 0)
        self.assertEqual(len(emitter.optional_nonnull_cases), expected)
        self.assertEqual(len(set(emitter.optional_nonnull_cases)), expected)
        self.assertEqual(
            presence_test.count("    try expectExplicitNullRejected("),
            expected,
        )
        for owner_name, wire_name in emitter.optional_nonnull_cases:
            with self.subTest(owner=owner_name, field=wire_name):
                self.assertIn(
                    f"protocol.{owner_name}, {json.dumps(wire_name)}",
                    presence_test,
                )

        self.assertIn(
            "capabilities: ?[]const []const u8 = null,",
            protocol,
        )
        self.assertIn("focused_at: ?u64 = null,", protocol)
        self.assertIn("replayed: ?bool = null,", protocol)


if __name__ == "__main__":
    unittest.main()
