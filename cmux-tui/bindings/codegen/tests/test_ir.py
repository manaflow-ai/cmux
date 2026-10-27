from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from codegen.ipc_meta import COMMAND_ATTRIBUTES, EVENT_ATTRIBUTES, FIELD_ATTRIBUTES
from codegen.ir import load_ir, load_ir_document, mutable_document
from codegen.validate import ValidationError

from support import schema_document, write_schema


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"


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

    def test_live_raw_v12_layout_and_history_contracts_are_exact(self) -> None:
        ir = load_ir(LIVE_SCHEMA)
        self.assertEqual(ir.mux_protocol, 12)

        def assert_field(
            type_name: str,
            field_name: str,
            *,
            kind: str,
            name: str,
            nullable: bool,
            since: int | None = None,
        ) -> None:
            field = ir.type(type_name)["fields"][field_name]
            self.assertEqual(field["type"], {"kind": kind, "name": name})
            self.assertEqual(field["presence"], "required")
            self.assertEqual(field["nullable"], nullable)
            self.assertEqual(field.get("since"), since)

        for type_name in ("RunResult", "TerminalPlacement"):
            assert_field(type_name, "surface", kind="ref", name="Id", nullable=True)
            assert_field(
                type_name,
                "terminal_id",
                kind="scalar",
                name="string",
                nullable=False,
                since=9 if type_name == "RunResult" else None,
            )
            for field_name in ("pane", "screen", "workspace"):
                assert_field(type_name, field_name, kind="ref", name="Id", nullable=True)
            assert_field(
                type_name,
                "lifecycle",
                kind="ref",
                name="TerminalLifecycle",
                nullable=False,
                since=11 if type_name == "RunResult" else None,
            )

        for type_name in ("RunResult", "TerminalPlacement"):
            assert_field(
                type_name,
                "exit",
                kind="ref",
                name="TerminalExit",
                nullable=True,
                since=11,
            )
            assert_field(
                type_name,
                "already_exited",
                kind="scalar",
                name="boolean",
                nullable=False,
                since=11,
            )
        assert_field(
            "RunResult",
            "terminal_revision",
            kind="scalar",
            name="uint64",
            nullable=False,
            since=11,
        )

        for type_name in ("ResolveTerminalResult", "TerminalRecord"):
            assert_field(
                type_name,
                "exit",
                kind="ref",
                name="TerminalExit",
                nullable=True,
            )

        assert_field(
            "MintTerminalRendererResult",
            "protocol_version",
            kind="scalar",
            name="uint16",
            nullable=False,
            since=11,
        )
        self.assertEqual(ir.command("mint-terminal-renderer-by-terminal")["since"], 11)

        def field_signature(field: dict) -> tuple:
            type_expression = field["type"]
            return (
                type_expression["kind"],
                type_expression.get("name"),
                field["presence"],
                field["nullable"],
                "default" in field,
                field.get("default"),
                field.get("since"),
                field.get("capability"),
            )

        expected = {
            "clear-history": {
                "since": 9,
                "capability": "clear-history-v1",
                "result": "EmptyResult",
                "fields": {
                    "surface": ("ref", "Id", "required", False, False, None, None, None),
                    "fallback_key": (
                        "ref",
                        "TerminalKeyInput",
                        "optional",
                        True,
                        True,
                        None,
                        9,
                        "clear-history-key-v1",
                    ),
                },
            },
            "new-pane-right": {
                "since": 9,
                "capability": "viewport-splits-v1",
                "result": "PaneSurfaceResult",
                "fields": {
                    "pane": ("ref", "Id", "required", False, False, None, None, None),
                    "width": (
                        "scalar",
                        "float32",
                        "optional",
                        True,
                        True,
                        None,
                        None,
                        None,
                    ),
                    "cols": (
                        "scalar",
                        "uint16",
                        "optional",
                        True,
                        True,
                        None,
                        None,
                        None,
                    ),
                    "rows": (
                        "scalar",
                        "uint16",
                        "optional",
                        True,
                        True,
                        None,
                        None,
                        None,
                    ),
                    # Placement additions: optional and capability-gated, so a
                    # v12 client that sends none of them is unaffected.
                    "cwd": (
                        "scalar",
                        "string",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "terminal-placement-env-v1",
                    ),
                    "env": (
                        "map",
                        None,
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "terminal-placement-env-v1",
                    ),
                    "terminal_id": (
                        "scalar",
                        "string",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "terminal-placement-env-v1",
                    ),
                    "keep": (
                        "scalar",
                        "boolean",
                        "optional",
                        False,
                        True,
                        False,
                        12,
                        "terminal-reap-v1",
                    ),
                    "shell_args": (
                        "array",
                        None,
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "terminal-shell-args-v1",
                    ),
                    "kind": (
                        "ref",
                        "PaneKind",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "pane-browser-kind-v1",
                    ),
                    "url": (
                        "scalar",
                        "string",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "pane-browser-kind-v1",
                    ),
                    # split-client-keys-v1: client-minted pane and tab ids.
                    "pane_id": (
                        "scalar",
                        "string",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "split-client-keys-v1",
                    ),
                    "tab_id": (
                        "scalar",
                        "string",
                        "optional",
                        True,
                        True,
                        None,
                        12,
                        "split-client-keys-v1",
                    ),
                },
            },
            "set-viewport-pane-width": {
                "since": 9,
                "capability": "viewport-column-resize-v1",
                "result": "ViewportPaneWidthResult",
                "fields": {
                    "pane": ("ref", "Id", "required", False, False, None, None, None),
                    "width": (
                        "scalar",
                        "float32",
                        "required",
                        False,
                        False,
                        None,
                        None,
                        None,
                    ),
                    "transaction": (
                        "scalar",
                        "uint64",
                        "optional",
                        True,
                        True,
                        None,
                        9,
                        "layout-undo-v1",
                    ),
                },
            },
            "undo-layout": {
                "since": 9,
                "capability": "layout-undo-v1",
                "result": "LayoutUndoResult",
                "fields": {
                    "pane": ("ref", "Id", "required", False, False, None, None, None),
                    "revision": (
                        "scalar",
                        "uint64",
                        "optional",
                        True,
                        True,
                        None,
                        None,
                        None,
                    ),
                    "confirm_close": (
                        "scalar",
                        "boolean",
                        "optional",
                        False,
                        True,
                        False,
                        None,
                        None,
                    ),
                },
            },
        }
        for wire_name, contract in expected.items():
            with self.subTest(command=wire_name):
                command = ir.command(wire_name)
                self.assertEqual(command["authority"], "control")
                self.assertEqual(command["since"], contract["since"])
                self.assertEqual(command["capability"], contract["capability"])
                self.assertEqual(
                    dict(command["result"]),
                    {"kind": "ref", "name": contract["result"]},
                )
                self.assertEqual(
                    {
                        name: field_signature(field)
                        for name, field in command["request"]["fields"].items()
                    },
                    contract["fields"],
                )

        transaction = ir.command("set-split-ratio")["request"]["fields"]["transaction"]
        self.assertEqual(
            field_signature(transaction),
            (
                "scalar",
                "uint64",
                "optional",
                True,
                True,
                None,
                9,
                "layout-undo-v1",
            ),
        )

        terminal_key = ir.type("TerminalKey")
        self.assertEqual(terminal_key["kind"], "enum")
        self.assertEqual(len(terminal_key["values"]), 113)
        self.assertEqual(terminal_key["values"][0], "unidentified")
        self.assertEqual(terminal_key["values"][-1], "f20")
        self.assertEqual(
            tuple(ir.type("LayoutUndoResult")["variants"]),
            (
                {"kind": "ref", "name": "LayoutUndoUndone"},
                {"kind": "ref", "name": "LayoutUndoConfirmationRequired"},
            ),
        )

    def test_live_raw_v10_tab_exposes_clear_history_key_fallback_support(self) -> None:
        field = load_ir(LIVE_SCHEMA).type("Tab")["fields"][
            "supports_clear_history_key_fallback"
        ]

        self.assertEqual(dict(field["type"]), {"kind": "scalar", "name": "boolean"})
        self.assertEqual(field["presence"], "optional")
        self.assertFalse(field["nullable"])
        self.assertEqual(field["since"], 9)
        self.assertEqual(field["capability"], "clear-history-key-v1")


def _framed_document() -> dict:
    """A valid document that declares families and every IPC attribute."""

    document = schema_document()
    document["families"] = {
        "core": {"id": 0x01, "description": "Core commands."},
        "terminal-io": {"id": 0x02, "description": "Terminal input and sizing."},
        "core-events": {"id": 0xC0, "description": "Core events."},
    }
    document["types"]["Size"] = {
        "kind": "object",
        "fields": {
            "cols": {
                "type": {"kind": "scalar", "name": "uint16"},
                "presence": "required",
                "nullable": False,
            },
            "rows": {
                "type": {"kind": "scalar", "name": "uint16"},
                "presence": "required",
                "nullable": False,
            },
        },
        "additional_properties": False,
    }
    listing = document["commands"]["list-workspaces"]
    listing.update(
        {
            "method_id": 0x0100,
            "priority": "control",
            "ordering": "independent",
            "durability": "read_only",
            "clients": ["macos", "cli"],
        }
    )
    document["commands"]["resize-view"] = {
        "authority": "control",
        "since": 1,
        "capability": None,
        "request": {
            "kind": "object",
            "fields": {
                "view": {
                    "type": {"kind": "scalar", "name": "string"},
                    "presence": "required",
                    "nullable": False,
                    "max_bytes": 64,
                },
                "size": {
                    "type": {"kind": "ref", "name": "Size"},
                    "presence": "required",
                    "nullable": False,
                },
                "delta": {
                    "type": {"kind": "scalar", "name": "int32"},
                    "presence": "optional",
                    "nullable": False,
                    "default": 0,
                    "omit_nil": True,
                },
            },
            "additional_properties": False,
        },
        "result": {"kind": "ref", "name": "EmptyResult"},
        "stream": None,
        "constraints": [],
        "method_id": 0x0200,
        "priority": "input",
        "durability": "memory",
        "payload": "binary",
        "layout_version": 1,
        "stream_scoped": True,
        "max_bytes": 128,
        "coalesce": {"key": ["view"], "additive": ["delta"]},
        "urgent": True,
        "clients": ["macos"],
    }
    document["commands"]["send-text"] = {
        "authority": "control",
        "since": 1,
        "capability": None,
        "request": {
            "kind": "object",
            "fields": {
                "surface": {
                    "type": {"kind": "ref", "name": "Id"},
                    "presence": "required",
                    "nullable": False,
                },
            },
            "additional_properties": False,
        },
        "result": {"kind": "ref", "name": "EmptyResult"},
        "stream": None,
        "constraints": [],
        "method_id": 0x0201,
        "priority": "control",
        "crosses_stream_ok": "closes the surface; queued input is moot",
        "spawns_terminal": True,
        "durability": "reply_before_journal",
    }
    document["events"]["workspace-created"].update(
        {"event_id": 0xC000, "priority": "control", "coalesce": {"key": ["workspace"]}}
    )
    return document


class IpcMetaTests(unittest.TestCase):
    """One failing fixture per rule of spec/transports.md, Framed IPC method attributes."""

    def assert_rejected(self, document: dict, message: str) -> None:
        with self.assertRaises(ValidationError) as caught:
            load_ir_document(document)
        self.assertIn(message, str(caught.exception))

    def test_framed_document_loads_and_indexes_ids(self) -> None:
        ir = load_ir_document(_framed_document())
        self.assertEqual(ir.family("terminal-io")["id"], 0x02)
        self.assertEqual(ir.command_by_method_id(0x0200), "resize-view")
        self.assertEqual(ir.command_by_method_id(0x0101), None)
        self.assertEqual(ir.event_by_event_id(0xC000), "workspace-created")
        self.assertEqual(ir.command("resize-view")["layout_version"], 1)

    def test_attributes_change_the_ir_hash_but_not_a_plain_document(self) -> None:
        plain = load_ir_document(schema_document())
        self.assertEqual(dict(plain.families), {})
        self.assertNotIn("families", plain.document)
        framed = load_ir_document(_framed_document())
        self.assertNotEqual(plain.ir_sha256, framed.ir_sha256)

    def test_live_schema_passes_the_ipc_rules(self) -> None:
        load_ir(LIVE_SCHEMA)

    def test_meta_schema_declares_every_ipc_attribute(self) -> None:
        meta = json.loads(
            (LIVE_SCHEMA.parent / "sdk-schema.schema.json").read_text(encoding="utf-8")
        )
        definitions = meta["$defs"]
        self.assertIn("families", meta["properties"])
        for definition, attributes in (
            ("command", COMMAND_ATTRIBUTES),
            ("event", EVENT_ATTRIBUTES),
            ("field", FIELD_ATTRIBUTES),
        ):
            with self.subTest(definition=definition):
                self.assertLessEqual(
                    set(attributes), set(definitions[definition]["properties"])
                )

    def test_rejects_duplicate_id_in_a_family(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["method_id"] = 0x0200
        self.assert_rejected(document, "duplicate id 0x0200 in family 'terminal-io'")

    def test_rejects_duplicate_event_id(self) -> None:
        document = _framed_document()
        document["events"]["workspace-closed"] = json.loads(
            json.dumps(document["events"]["workspace-created"])
        )
        self.assert_rejected(document, "duplicate id 0xC000 in family 'core-events'")

    def test_rejects_duplicate_family_id(self) -> None:
        document = _framed_document()
        document["families"]["core-again"] = {"id": 0x01, "description": "Again."}
        self.assert_rejected(document, "duplicates family 'core'")

    def test_rejects_id_in_an_undeclared_family(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["method_id"] = 0x0301
        self.assert_rejected(document, "family 0x03 is not declared")

    def test_rejects_command_id_in_an_event_family(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["method_id"] = 0xC001
        self.assert_rejected(document, "outside the command family range")

    def test_rejects_event_id_in_a_command_family(self) -> None:
        document = _framed_document()
        document["events"]["workspace-created"]["event_id"] = 0x0105
        self.assert_rejected(document, "outside the event family range")

    def test_rejects_family_in_the_resource_v2_range(self) -> None:
        document = _framed_document()
        document["families"]["v2"] = {"id": 0x60, "description": "Resource ops."}
        self.assert_rejected(document, "reserved for resource-operations-v2")

    def test_rejects_family_out_of_any_range(self) -> None:
        document = _framed_document()
        document["families"]["none"] = {"id": 0xFF, "description": "Out of range."}
        self.assert_rejected(document, "must be a command family")

    def test_rejects_method_id_wider_than_u16(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["method_id"] = 0x10000
        self.assert_rejected(document, "must be a u16")

    def test_rejects_unknown_priority(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["priority"] = "realtime"
        self.assert_rejected(document, "must be one of input, control, bulk, background")

    def test_framed_document_requires_id_and_priority_everywhere(self) -> None:
        document = _framed_document()
        del document["commands"]["list-workspaces"]["method_id"]
        del document["events"]["workspace-created"]["priority"]
        with self.assertRaises(ValidationError) as caught:
            load_ir_document(document)
        text = str(caught.exception)
        self.assertIn("$.commands.list-workspaces: IPC attributes need method_id", text)
        self.assertIn("$.events.workspace-created: IPC attributes need priority", text)

    def test_framed_command_requires_durability(self) -> None:
        document = _framed_document()
        del document["commands"]["send-text"]["durability"]
        self.assert_rejected(document, "$.commands.send-text: IPC attributes need durability")

    def test_rejects_independent_ordering_on_a_mutating_command(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["ordering"] = "independent"
        self.assert_rejected(document, "independent ordering needs durability 'read_only'")

    def test_rejects_independent_ordering_on_a_stream_scoped_command(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["ordering"] = "independent"
        self.assert_rejected(document, "a stream-scoped command cannot be independent")

    def test_rejects_surface_target_without_stream_rule(self) -> None:
        document = _framed_document()
        del document["commands"]["send-text"]["crosses_stream_ok"]
        self.assert_rejected(document, "targets a stream through surface")

    def test_rejects_crosses_stream_ok_without_a_reason(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["crosses_stream_ok"] = "  "
        self.assert_rejected(document, "crosses_stream_ok: must be a non-empty reason")

    def test_rejects_stream_scoped_and_crosses_stream_ok_together(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["crosses_stream_ok"] = "both"
        self.assert_rejected(document, "stream_scoped and crosses_stream_ok exclude each other")

    def test_rejects_unbounded_binary_string_field(self) -> None:
        document = _framed_document()
        del document["commands"]["resize-view"]["request"]["fields"]["view"]["max_bytes"]
        self.assert_rejected(document, "a binary string field needs max_bytes")

    def test_rejects_unbounded_binary_array(self) -> None:
        document = _framed_document()
        document["types"]["Size"]["fields"]["cols"]["type"] = {
            "kind": "array",
            "items": {"kind": "scalar", "name": "uint16"},
        }
        self.assert_rejected(document, "a binary array needs max_items")

    def test_rejects_map_in_a_binary_layout(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["result"] = {
            "kind": "map",
            "values": {"kind": "scalar", "name": "uint16"},
        }
        self.assert_rejected(document, "map has no bounded binary layout")

    def test_rejects_open_object_in_a_binary_layout(self) -> None:
        document = _framed_document()
        document["types"]["Size"]["additional_properties"] = True
        self.assert_rejected(document, "a binary object cannot allow additional properties")

    def test_rejects_binary_payload_without_layout_version(self) -> None:
        document = _framed_document()
        del document["commands"]["resize-view"]["layout_version"]
        self.assert_rejected(document, "a binary payload needs layout_version")

    def test_rejects_layout_version_out_of_byte_range(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["layout_version"] = 256
        self.assert_rejected(document, "must be an integer 1-255")

    def test_rejects_layout_version_on_a_json_payload(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["layout_version"] = 1
        self.assert_rejected(document, "layout_version: needs payload 'binary'")

    def test_rejects_max_bytes_above_the_frame_limit(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["max_bytes"] = 32 * 1024 * 1024 + 1
        self.assert_rejected(document, "max_bytes: must be an integer 1-33554432")

    def test_rejects_max_bytes_on_a_non_string_field(self) -> None:
        document = _framed_document()
        document["types"]["Size"]["fields"]["cols"]["max_bytes"] = 4
        self.assert_rejected(document, "bounds string fields and arrays of strings only")

    def test_rejects_coalesce_key_naming_an_unknown_field(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["coalesce"]["key"] = ["missing"]
        self.assert_rejected(document, "names unknown field 'missing'")

    def test_rejects_non_numeric_additive_coalesce_field(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["coalesce"]["additive"] = ["size"]
        self.assert_rejected(document, "'size' is not numeric")

    def test_rejects_urgent_on_bulk_priority(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["priority"] = "bulk"
        self.assert_rejected(document, "urgent needs priority input or control")

    def test_rejects_read_only_terminal_spawn(self) -> None:
        document = _framed_document()
        document["commands"]["send-text"]["durability"] = "read_only"
        self.assert_rejected(document, "a terminal-spawning command is not read_only")

    def test_rejects_unknown_client(self) -> None:
        document = _framed_document()
        document["commands"]["list-workspaces"]["clients"] = ["macos", "watch"]
        self.assert_rejected(document, "must be one of macos, ios, cli, sdk")

    def test_rejects_omit_nil_on_a_required_field(self) -> None:
        document = _framed_document()
        document["types"]["Size"]["fields"]["rows"]["omit_nil"] = True
        self.assert_rejected(document, "a required field cannot be omitted")

    def test_rejects_default_that_does_not_match_the_type(self) -> None:
        document = _framed_document()
        fields = document["commands"]["resize-view"]["request"]["fields"]
        fields["delta"]["default"] = "zero"
        self.assert_rejected(document, "default: does not match the field type")

    def test_rejects_priority_changed_reason_without_priority(self) -> None:
        document = _framed_document()
        listing = document["commands"]["list-workspaces"]
        del listing["priority"]
        listing["priority_changed_reason"] = "moved to bulk"
        self.assert_rejected(document, "priority_changed_reason: needs priority")

    def test_rejects_unknown_family_key(self) -> None:
        document = _framed_document()
        document["families"]["core"]["ordinal_base"] = 0
        self.assert_rejected(document, "$.families.core.ordinal_base: unknown key")

    def test_accepts_ids_below_next_ordinal(self) -> None:
        document = _framed_document()
        document["families"]["terminal-io"]["next_ordinal"] = 9
        self.assertEqual(load_ir_document(document).family("terminal-io")["next_ordinal"], 9)

    def test_rejects_an_id_at_or_above_next_ordinal(self) -> None:
        document = _framed_document()
        document["families"]["terminal-io"]["next_ordinal"] = 1
        self.assert_rejected(
            document, "ordinal 1 of 0x0201 is not below family 'terminal-io' next_ordinal 1"
        )

    def test_rejects_next_ordinal_out_of_range(self) -> None:
        document = _framed_document()
        document["families"]["core"]["next_ordinal"] = 257
        self.assert_rejected(document, "$.families.core.next_ordinal: must be an integer 0-256")

    def test_rejects_max_bytes_on_an_array_of_numbers(self) -> None:
        document = _framed_document()
        document["types"]["Size"]["fields"]["cols"] = {
            "type": {
                "kind": "array",
                "items": {"kind": "scalar", "name": "uint16"},
                "max_items": 4,
            },
            "presence": "required",
            "nullable": False,
            "max_bytes": 4,
        }
        self.assert_rejected(document, "bounds string fields and arrays of strings only")

    def test_accepts_a_bounded_array_of_string_ids_in_a_binary_layout(self) -> None:
        ir = load_ir_document(_with_name_list(_framed_document(), max_bytes=32))
        names = ir.command("resize-view")["request"]["fields"]["names"]
        self.assertEqual(names["max_bytes"], 32)

    def test_rejects_an_array_of_string_ids_without_an_item_bound(self) -> None:
        document = _with_name_list(_framed_document(), max_bytes=None)
        self.assert_rejected(
            document,
            "$.commands.resize-view.request.fields.names.items: "
            "a binary string field needs max_bytes",
        )

    def test_rejects_recursive_type_in_a_binary_layout(self) -> None:
        document = _framed_document()
        document["types"]["Node"] = {
            "kind": "object",
            "fields": {
                "next": {
                    "type": {"kind": "ref", "name": "Node"},
                    "presence": "optional",
                    "nullable": True,
                }
            },
            "additional_properties": False,
        }
        document["commands"]["resize-view"]["result"] = {"kind": "ref", "name": "Node"}
        self.assert_rejected(document, "recursive type 'Node' has no bounded binary layout")

    def test_rejects_opaque_json_in_a_binary_layout(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["result"] = {
            "kind": "opaque_json",
            "reason": "free-form",
        }
        self.assert_rejected(document, "opaque_json has no bounded binary layout")

    def test_rejects_untagged_union_in_a_binary_layout(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["result"] = {
            "kind": "untagged_union",
            "variants": [
                {"kind": "scalar", "name": "uint16"},
                {"kind": "scalar", "name": "boolean"},
            ],
        }
        self.assert_rejected(document, "untagged_union has no bounded binary layout")

    def test_rejects_coalesce_field_that_is_key_and_additive(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["coalesce"] = {
            "key": ["view", "delta"],
            "additive": ["delta"],
        }
        self.assert_rejected(document, "'delta' is also a key field")

    def test_rejects_unknown_coalesce_key(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["coalesce"]["merge"] = ["delta"]
        self.assert_rejected(document, "coalesce.merge: unknown key")

    def test_rejects_family_name_that_is_not_kebab_case(self) -> None:
        document = _framed_document()
        document["families"]["Core_IO"] = {"id": 0x03, "description": "Bad name."}
        self.assert_rejected(document, "family name must be kebab-case")

    def test_rejects_family_without_a_description(self) -> None:
        document = _framed_document()
        del document["families"]["core"]["description"]
        self.assert_rejected(document, "families.core.description: must be a non-empty string")

    def test_rejects_duplicate_clients(self) -> None:
        document = _framed_document()
        document["commands"]["list-workspaces"]["clients"] = ["macos", "macos"]
        self.assert_rejected(document, "clients: must contain unique values")

    def test_rejects_independent_ordering_without_durability(self) -> None:
        document = _framed_document()
        del document["commands"]["list-workspaces"]["durability"]
        self.assert_rejected(document, "independent ordering needs durability 'read_only'")

    def test_rejects_null_default_on_a_non_nullable_field(self) -> None:
        document = _framed_document()
        fields = document["commands"]["resize-view"]["request"]["fields"]
        fields["delta"]["default"] = None
        self.assert_rejected(document, "delta.default: does not match the field type")

    def test_accepts_null_default_on_a_nullable_field(self) -> None:
        document = _framed_document()
        delta = document["commands"]["resize-view"]["request"]["fields"]["delta"]
        delta.update({"nullable": True, "default": None})
        load_ir_document(document)

    def test_malformed_types_are_issues_not_crashes(self) -> None:
        """Bad input reaches the IPC rules before validate_type reports it."""

        def broken_field(field_type: object, default: object) -> dict:
            return {
                "type": field_type,
                "presence": "optional",
                "nullable": False,
                "default": default,
            }

        cases = {
            "ref name is a list": broken_field({"kind": "ref", "name": ["Id"]}, 0),
            "kind is a list": broken_field({"kind": ["scalar"], "name": "uint16"}, 0),
            "enum values is not an array": broken_field({"kind": "ref", "name": "Mode"}, "a"),
            "union variants is not an array": broken_field(
                {"kind": "untagged_union", "variants": 5}, 0
            ),
        }
        for label, field in cases.items():
            for name, build in (("plain", schema_document), ("framed", _framed_document)):
                with self.subTest(case=label, document=name):
                    document = build()
                    document["types"]["Mode"] = {"kind": "enum", "values": 5}
                    document["types"]["Broken"] = {
                        "kind": "object",
                        "fields": {"value": field},
                        "additional_properties": False,
                    }
                    with self.assertRaises(ValidationError):
                        load_ir_document(document)

    def test_malformed_ref_in_a_binary_layout_is_an_issue(self) -> None:
        document = _framed_document()
        fields = document["commands"]["resize-view"]["request"]["fields"]
        fields["size"]["type"] = {"kind": "ref", "name": ["Size"]}
        with self.assertRaises(ValidationError):
            load_ir_document(document)

    def test_malformed_coalesce_field_is_an_issue(self) -> None:
        document = _framed_document()
        document["commands"]["resize-view"]["request"]["fields"]["delta"] = "oops"
        with self.assertRaises(ValidationError):
            load_ir_document(document)


def _with_name_list(document: dict, *, max_bytes: int | None) -> dict:
    """Give resize-view a binary ``names`` member: an array of a string alias."""

    document["types"]["Name"] = {
        "kind": "alias",
        "target": {"kind": "scalar", "name": "string"},
    }
    names: dict = {
        "type": {"kind": "array", "items": {"kind": "ref", "name": "Name"}, "max_items": 4},
        "presence": "optional",
        "nullable": False,
    }
    if max_bytes is not None:
        names["max_bytes"] = max_bytes
    document["commands"]["resize-view"]["request"]["fields"]["names"] = names
    return document


if __name__ == "__main__":
    unittest.main()
