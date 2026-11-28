from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

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
                "result": "SurfaceResult",
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
                },
            },
            "set-viewport-pane-width": {
                "since": 9,
                "capability": "viewport-column-resize-v1",
                "result": "EmptyResult",
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


if __name__ == "__main__":
    unittest.main()
