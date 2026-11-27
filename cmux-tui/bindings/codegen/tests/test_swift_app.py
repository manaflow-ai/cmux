"""The Swift app emitter: CmuxNextDaemon request types from the SDK schema (codegen/swift_app)."""

from __future__ import annotations

import copy
import re
import tempfile
import unittest
from pathlib import Path
from typing import Any

from codegen.ir import load_ir, load_ir_document
from codegen.swift_app import emit, generate
from codegen.swift_app.emit import HEADER_MARK, BindingError, render

from support import schema_document

CODEGEN = Path(__file__).resolve().parents[1]
REPO = CODEGEN.parents[2]


def _field(type_: dict[str, Any], *, required: bool = True, nullable: bool = False, **extra: Any) -> dict[str, Any]:
    field: dict[str, Any] = {"type": type_, "presence": "required" if required else "optional", "nullable": nullable}
    if not required:
        field["default"] = None if nullable else extra.pop("default", None)
    field.update(extra)
    return field


ID = {"kind": "ref", "name": "Id"}


def layout_document() -> dict[str, Any]:
    """The shared fixture plus three layout commands, their result and two enums."""
    document = copy.deepcopy(schema_document())
    types = document["types"]
    types["PaneDirection"] = {"kind": "enum", "values": ["left", "right", "up", "down"]}
    types["RowHeight"] = {
        "kind": "object",
        "fields": {"row": _field(ID), "height": _field({"kind": "scalar", "name": "uint32"})},
        "additional_properties": False,
    }
    types["ZoomPaneResult"] = {
        "kind": "object",
        "fields": {
            "pane": _field(ID),
            "zoomed": _field({"kind": "scalar", "name": "boolean"}),
            "zoomed_pane": _field(ID, nullable=True),
        },
        "additional_properties": False,
    }

    def command(request_fields: dict[str, Any], result: dict[str, Any], capability: str | None = None) -> dict[str, Any]:
        return {
            "authority": "control",
            "since": 9,
            "capability": capability,
            "request": {"kind": "object", "fields": request_fields, "additional_properties": False},
            "result": result,
            "stream": None,
            "constraints": [],
        }

    commands = document["commands"]
    commands["swap-pane"] = command(
        {
            "pane": _field(ID),
            "dir": _field({"kind": "ref", "name": "PaneDirection"}, required=False, nullable=True),
            "target": _field(ID, required=False, nullable=True),
        },
        {"kind": "ref", "name": "EmptyResult"},
    )
    commands["set-split-ratio"] = command(
        {
            "split": _field(ID),
            "ratio": _field(
                {"kind": "scalar", "name": "float32"},
                constraints=[{"clamped_minimum": 0.05, "clamped_maximum": 0.95}],
            ),
            "transaction": _field({"kind": "scalar", "name": "uint64"}, required=False, nullable=True),
            "confirm_close": _field({"kind": "scalar", "name": "boolean"}, required=False, default=False),
        },
        {"kind": "ref", "name": "EmptyResult"},
        capability="layout-undo-v1",
    )
    commands["zoom-pane"] = command(
        {
            "pane": _field(ID, required=False, nullable=True),
            "mode": _field({"kind": "enum", "values": ["toggle", "on", "off"]}, required=False, nullable=True),
        },
        {"kind": "ref", "name": "ZoomPaneResult"},
    )
    commands["set-row-heights"] = command(
        {"column": _field(ID), "heights": _field({"kind": "array", "items": {"kind": "ref", "name": "RowHeight"}})},
        {"kind": "ref", "name": "EmptyResult"},
    )
    return document


def layout_bindings() -> dict[str, Any]:
    return {
        "output_root": "Sources/Requests",
        "ids": {"pane": "PaneID", "split": "SplitID", "column": "ColumnID", "zoomed_pane": "PaneID"},
        "types": {"RowHeight": "RowHeightValue"},
        "families": {
            "Layout": {
                "enums": {"PaneDirection": {"doc": ["A neighbor direction."]}},
                "requests": {
                    "swap-pane": {
                        "name": "SwapPaneRequest",
                        "order": ["pane", "dir", "target"],
                        "fields": {"target": {"type": "PaneID"}},
                    },
                    "set-split-ratio": {
                        "name": "SetSplitRatioRequest",
                        "doc": ["Divider drag."],
                        "order": ["split", "ratio"],
                    },
                    "zoom-pane": {"name": "ZoomPaneRequest", "order": ["pane", "mode"], "response": "generate"},
                    "set-row-heights": {"name": "SetRowHeightsRequest", "order": ["column", "heights"]},
                },
            }
        },
    }


def rendered(document: dict[str, Any] | None = None, bindings: dict[str, Any] | None = None) -> dict[str, str]:
    return render(load_ir_document(document or layout_document()), bindings or layout_bindings())


class RenderTests(unittest.TestCase):
    def test_one_file_per_request_and_enum_under_its_family(self) -> None:
        self.assertEqual(
            sorted(rendered()),
            [
                "Layout/PaneDirection.generated.swift",
                "Layout/SetRowHeightsRequest.generated.swift",
                "Layout/SetSplitRatioRequest.generated.swift",
                "Layout/SwapPaneRequest.generated.swift",
                "Layout/ZoomPaneRequest.generated.swift",
            ],
        )

    def test_every_file_starts_with_the_ownership_header(self) -> None:
        for path, source in rendered().items():
            with self.subTest(path=path):
                self.assertEqual(source.splitlines()[0], HEADER_MARK)
                self.assertIn("Do not edit", source.splitlines()[1])

    def test_a_request_names_its_command_capability_typed_fields_and_wire_keys(self) -> None:
        source = rendered()["Layout/SetSplitRatioRequest.generated.swift"]
        self.assertIn("/// Divider drag.\npublic struct SetSplitRatioRequest: DaemonRequest {", source)
        self.assertIn("    public typealias Response = EmptyResponse\n", source)
        self.assertIn('    public static let command = "set-split-ratio"\n', source)
        self.assertIn('    public static let requiredCapability: String? = "layout-undo-v1"\n', source)
        self.assertIn("    public var split: SplitID\n", source)
        # float32 is Double in the app: the app keeps its precision, the daemon narrows.
        self.assertIn("    /// Clamped by the daemon to 0.05...0.95.\n    public var ratio: Double\n", source)
        self.assertIn("    public var transaction: UInt64?\n", source)
        self.assertIn("    public var confirmClose: Bool?\n", source)
        self.assertIn('        case confirmClose = "confirm_close"\n', source)
        # `order` first, then the rest: required before optional, each by wire name.
        self.assertIn(
            "    public init(split: SplitID, ratio: Double, confirmClose: Bool? = nil, transaction: UInt64? = nil) {\n",
            source,
        )

    def test_a_field_gated_by_a_capability_says_so(self) -> None:
        document = layout_document()
        fields = document["commands"]["set-split-ratio"]["request"]["fields"]
        fields["transaction"]["capability"] = "layout-undo-v1"
        fields["transaction"]["since"] = 9
        source = rendered(document)["Layout/SetSplitRatioRequest.generated.swift"]
        self.assertIn(
            "    /// Needs `layout-undo-v1` (protocol 9); leave it nil for a daemon that does not serve it.\n"
            "    public var transaction: UInt64?\n",
            source,
        )

    def test_a_command_without_a_capability_declares_none(self) -> None:
        self.assertNotIn("requiredCapability", rendered()["Layout/SwapPaneRequest.generated.swift"])

    def test_required_fields_are_always_encoded_and_optional_ones_only_when_set(self) -> None:
        source = rendered()["Layout/SwapPaneRequest.generated.swift"]
        self.assertIn("        try container.encode(pane, forKey: .pane)\n", source)
        self.assertIn("        try container.encodeIfPresent(dir, forKey: .dir)\n", source)
        self.assertIn("        try container.encodeIfPresent(target, forKey: .target)\n", source)
        self.assertIn("    public var target: PaneID?\n", source)
        self.assertIn("    public var dir: PaneDirection?\n", source)

    def test_a_required_nullable_field_is_encoded_as_null_when_nil(self) -> None:
        document = layout_document()
        document["commands"]["swap-pane"]["request"]["fields"]["target"] = _field(ID, nullable=True)
        source = rendered(document)["Layout/SwapPaneRequest.generated.swift"]
        self.assertIn("    public var target: PaneID?\n", source)
        self.assertIn("        try container.encode(target, forKey: .target)\n", source)

    def test_a_bound_schema_type_uses_the_swift_type(self) -> None:
        source = rendered()["Layout/SetRowHeightsRequest.generated.swift"]
        self.assertIn("    public var heights: [RowHeightValue]\n", source)

    def test_a_schema_enum_becomes_a_string_enum(self) -> None:
        source = rendered()["Layout/PaneDirection.generated.swift"]
        self.assertIn("/// A neighbor direction.\npublic enum PaneDirection: String, Sendable, Hashable, Codable {", source)
        self.assertIn("    case left\n    case right\n    case up\n    case down\n", source)

    def test_an_inline_enum_is_nested_and_named_after_its_field(self) -> None:
        source = rendered()["Layout/ZoomPaneRequest.generated.swift"]
        self.assertIn("    public enum Mode: String, Sendable, Hashable, Codable {\n", source)
        self.assertIn("    public var mode: Mode?\n", source)

    def test_a_generated_response_decodes_the_result_object(self) -> None:
        source = rendered()["Layout/ZoomPaneRequest.generated.swift"]
        self.assertIn("    public struct Response: Decodable, Sendable, Equatable {\n", source)
        self.assertIn("        public var pane: PaneID\n", source)
        self.assertIn("        public var zoomedPane: PaneID?\n", source)
        self.assertIn('            case zoomedPane = "zoomed_pane"\n', source)
        self.assertNotIn("typealias Response", source)

    def test_a_hand_written_response_is_left_to_the_family(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["zoom-pane"]["response"] = "hand-written"
        source = rendered(bindings=bindings)["Layout/ZoomPaneRequest.generated.swift"]
        self.assertNotIn("Response", source)

    def test_a_named_response_is_a_typealias(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["zoom-pane"]["response"] = "EmptyResponse"
        source = rendered(bindings=bindings)["Layout/ZoomPaneRequest.generated.swift"]
        self.assertIn("    public typealias Response = EmptyResponse\n", source)

    def test_identifiers_follow_swift_acronym_style_and_escape_keywords(self) -> None:
        self.assertEqual(emit.swift_name("terminal_id"), "terminalID")
        self.assertEqual(emit.swift_name("surface_ids"), "surfaceIDs")
        self.assertEqual(emit.swift_name("open_url"), "openURL")
        self.assertEqual(emit.swift_name("started_at_ms"), "startedAtMs")
        self.assertEqual(emit.swift_name("default"), "`default`")

    def test_output_is_deterministic_and_passes_the_hygiene_rules(self) -> None:
        first, second = rendered(), rendered()
        self.assertEqual(first, second)
        for path, source in first.items():
            with self.subTest(path=path):
                self.assertTrue(source.endswith("}\n"))
                self.assertNotIn("\n\n\n", source)
                self.assertIsNone(re.search(r"[ \t]+\n", source))
                self.assertNotIn(";", source)

    def test_a_file_stays_within_the_god_file_limits(self) -> None:
        for path, source in rendered().items():
            with self.subTest(path=path):
                top_level = re.findall(r"^(?:public )?(?:struct|enum|class|actor|extension) ", source, re.M)
                self.assertLessEqual(len(top_level), 3)
                self.assertLess(source.count("\n"), 400)


class BindingErrorTests(unittest.TestCase):
    def assert_refused(self, message: str, document: dict[str, Any] | None = None,
                       bindings: dict[str, Any] | None = None) -> None:
        with self.assertRaises(BindingError) as raised:
            rendered(document, bindings)
        self.assertIn(message, str(raised.exception))

    def test_an_id_field_without_a_swift_id_type_is_refused(self) -> None:
        bindings = layout_bindings()
        del bindings["families"]["Layout"]["requests"]["swap-pane"]["fields"]
        self.assert_refused("swap-pane.target", bindings=bindings)

    def test_an_unbound_object_type_is_refused(self) -> None:
        bindings = layout_bindings()
        del bindings["types"]["RowHeight"]
        self.assert_refused("RowHeight", bindings=bindings)

    def test_an_enum_neither_generated_nor_bound_is_refused(self) -> None:
        bindings = layout_bindings()
        del bindings["families"]["Layout"]["enums"]["PaneDirection"]
        self.assert_refused("PaneDirection", bindings=bindings)

    def test_a_result_other_than_empty_needs_a_response_binding(self) -> None:
        bindings = layout_bindings()
        del bindings["families"]["Layout"]["requests"]["zoom-pane"]["response"]
        self.assert_refused("zoom-pane", bindings=bindings)

    def test_a_command_missing_from_the_schema_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["no-such-command"] = {"name": "NoSuchRequest"}
        self.assert_refused("no-such-command", bindings=bindings)

    def test_an_override_for_a_field_the_command_lacks_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"]["fields"]["nope"] = {"type": "PaneID"}
        self.assert_refused("swap-pane.nope", bindings=bindings)

    def test_a_type_name_that_is_not_a_swift_identifier_is_refused(self) -> None:
        for name in ("../../Escape", "Not-Valid", "1Request", "struct"):
            with self.subTest(name=name):
                bindings = layout_bindings()
                bindings["families"]["Layout"]["requests"]["swap-pane"]["name"] = name
                self.assert_refused(repr(name), bindings=bindings)

    def test_a_family_that_is_not_one_folder_name_is_refused(self) -> None:
        for family in ("../Escape", "a/b", "", "."):
            with self.subTest(family=family):
                bindings = layout_bindings()
                bindings["families"] = {family: bindings["families"]["Layout"]}
                self.assert_refused(f"family {family!r}", bindings=bindings)

    def test_a_required_field_gated_by_a_capability_is_refused(self) -> None:
        document = layout_document()
        document["commands"]["set-split-ratio"]["request"]["fields"]["split"]["capability"] = "layout-undo-v1"
        self.assert_refused("set-split-ratio.split: a required field gated by layout-undo-v1", document)

    def test_two_fields_with_one_swift_name_are_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"]["fields"]["dir"] = {"name": "target"}
        self.assert_refused("swap-pane: two fields become the same Swift name", bindings=bindings)

    def test_two_bindings_generating_one_type_are_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["zoom-pane"]["name"] = "SwapPaneRequest"
        self.assert_refused("two bindings generate the Swift type SwapPaneRequest", bindings=bindings)

    def test_an_unknown_protocol_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"]["protocol"] = "Encodable"
        self.assert_refused("swap-pane: protocol must be one of", bindings=bindings)

    def test_binding_a_type_the_schema_lacks_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["types"]["NoSuchType"] = "Whatever"
        self.assert_refused("types binds NoSuchType", bindings=bindings)

    def test_a_request_that_is_not_an_object_is_refused(self) -> None:
        document = layout_document()
        document["commands"]["swap-pane"]["request"] = {"kind": "ref", "name": "EmptyResult"}
        # The schema validator refuses it first; the emitter's own check is the second line.
        from codegen.validate import ValidationError

        with self.assertRaises((ValidationError, BindingError)):
            rendered(document)

    def test_an_order_naming_an_unknown_field_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"]["order"] = ["pane", "nope"]
        self.assert_refused("swap-pane", bindings=bindings)


class CheckAndWriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        # The repository sits one level down, so a path that escapes it stays inside this temp folder
        # (`../Requests` is temp/Requests, never a shared folder) and tearDown removes it.
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        import json

        (self.root / "schema.json").write_text(json.dumps(layout_document()), encoding="utf-8")
        (self.root / "bindings.json").write_text(json.dumps(layout_bindings()), encoding="utf-8")
        self.out = self.root / "Sources" / "Requests"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_mode(self, mode: str) -> list[str]:
        return generate.run(
            mode=mode, schema=self.root / "schema.json", bindings=self.root / "bindings.json", repo_root=self.root
        )

    def test_check_fails_until_written_then_passes(self) -> None:
        self.assertTrue(any("missing" in problem for problem in self.run_mode("check")))
        self.assertEqual(self.run_mode("write"), [])
        self.assertEqual(self.run_mode("check"), [])

    def test_a_hand_edit_of_a_generated_file_fails_the_check(self) -> None:
        self.run_mode("write")
        path = self.out / "Layout" / "SwapPaneRequest.generated.swift"
        path.write_text(path.read_text(encoding="utf-8") + "// edit\n", encoding="utf-8")
        self.assertEqual(self.run_mode("check"), ["changed Layout/SwapPaneRequest.generated.swift"])

    def test_a_stale_owned_file_fails_the_check_and_write_removes_it(self) -> None:
        self.run_mode("write")
        stale = self.out / "Old" / "OldRequest.generated.swift"
        stale.parent.mkdir(parents=True)
        stale.write_text(HEADER_MARK + "\n", encoding="utf-8")
        self.assertEqual(self.run_mode("check"), ["stale Old/OldRequest.generated.swift"])
        self.assertEqual(self.run_mode("write"), [])
        self.assertFalse(stale.exists())

    def test_an_output_root_outside_the_repository_is_refused(self) -> None:
        import json

        for root in ("/abs/Requests", "../Requests", "Sources/../../Requests", ""):
            with self.subTest(root=root):
                bindings = layout_bindings()
                bindings["output_root"] = root
                (self.root / "bindings.json").write_text(json.dumps(bindings), encoding="utf-8")
                with self.assertRaises(BindingError):
                    self.run_mode("write")
                self.assertFalse((self.root.parent / "Requests").exists())

    def test_a_hand_written_file_at_a_generated_path_is_never_replaced(self) -> None:
        path = self.out / "Layout" / "SwapPaneRequest.generated.swift"
        path.parent.mkdir(parents=True)
        path.write_text("// hand-written\n", encoding="utf-8")
        for mode in ("check", "write"):
            with self.subTest(mode=mode):
                with self.assertRaises(BindingError):
                    self.run_mode(mode)
                self.assertEqual(path.read_text(encoding="utf-8"), "// hand-written\n")

    def test_a_generated_file_of_another_generator_is_not_owned(self) -> None:
        self.run_mode("write")
        other = self.out / "Layout" / "Other.generated.swift"
        other.write_text("// GENERATED by another tool\n", encoding="utf-8")
        self.assertEqual(self.run_mode("check"), [])
        self.run_mode("write")
        self.assertTrue(other.exists())


class SdkGeneratorHookTests(unittest.TestCase):
    def test_the_swift_step_reads_the_schema_the_sdk_step_read(self) -> None:
        from unittest import mock

        from codegen import generate as sdk_generate

        with mock.patch.object(sdk_generate, "run_generation", return_value=()), \
                mock.patch("codegen.page_router.main", return_value=0), \
                mock.patch("codegen.swift_app.generate.main", return_value=0) as swift_main:
            self.assertEqual(sdk_generate.main(["--check", "--schema", "/some/schema.json"]), 0)
        swift_main.assert_called_once_with(["--check", "--schema", "/some/schema.json"])

    def test_a_failing_swift_step_fails_the_sdk_generator(self) -> None:
        from unittest import mock

        from codegen import generate as sdk_generate

        with mock.patch.object(sdk_generate, "run_generation", return_value=()), \
                mock.patch("codegen.page_router.main", return_value=0), \
                mock.patch("codegen.swift_app.generate.main", return_value=1):
            self.assertEqual(sdk_generate.main(["--check"]), 1)


class RepositoryBindingsTests(unittest.TestCase):
    def test_the_repository_bindings_render_against_the_repository_schema(self) -> None:
        bindings = generate.load_bindings(generate.DEFAULT_BINDINGS)
        self.assertTrue(generate.output_root(REPO, bindings).is_dir())
        files = render(load_ir(generate.DEFAULT_SCHEMA), bindings)
        self.assertEqual(len(files), sum(
            len(family.get("enums", {})) + len(family.get("requests", {}))
            for family in bindings.get("families", {}).values()
        ))

    def test_the_layout_bindings_render_against_the_repository_schema(self) -> None:
        """The binding the Layout family will use (backlog A4b) still renders against today's schema."""
        bindings = generate.load_bindings(generate.DEFAULT_BINDINGS)
        bindings["ids"] = {"column": "ColumnID", "pane": "PaneID", "split": "SplitID", "zoomed_pane": "PaneID"}
        bindings["types"] = {"RowHeight": "RowHeightValue"}
        bindings["families"] = {"Layout": {
            "enums": {"ColumnMoveDirection": {}, "PaneDirection": {}},
            "requests": {
                "move-column": {"name": "MoveColumnRequest", "response": "EmptyResponse"},
                "set-column-dock": {"name": "SetColumnDockRequest", "response": "EmptyResponse"},
                "set-row-heights": {"name": "SetRowHeightsRequest", "response": "EmptyResponse"},
                "set-split-ratio": {"name": "SetSplitRatioRequest"},
                "set-viewport-pane-width": {"name": "SetColumnWidthRequest", "response": "EmptyResponse"},
                "swap-pane": {"name": "SwapPaneRequest", "fields": {"target": {"type": "PaneID"}}},
                "undo-layout": {"name": "UndoLayoutRequest", "response": "hand-written"},
                "zoom-pane": {"name": "ZoomPaneRequest", "response": "generate"},
            },
        }}
        files = render(load_ir(generate.DEFAULT_SCHEMA), bindings)
        self.assertEqual(len(files), 10)
        self.assertIn('public static let command = "set-viewport-pane-width"', files["Layout/SetColumnWidthRequest.generated.swift"])


if __name__ == "__main__":
    unittest.main()
