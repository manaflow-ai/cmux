"""The Swift app emitter: CmuxNextDaemon request types from the SDK schema (codegen/swift_app)."""

from __future__ import annotations

import copy
import io
import re
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

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
        "sources_root": "Sources/Daemon",
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


class OutAndCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        # The repository sits one level down, so a path that escapes it stays inside this temp folder.
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.write_inputs(layout_bindings())
        self.sources = self.root / "Sources" / "Daemon"
        self.sources.mkdir(parents=True)
        # The plugin's work folder: outside every package Sources folder.
        self.out = Path(self.temp.name) / "plugin-work" / "Generated"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_inputs(self, bindings: dict[str, Any]) -> None:
        import json

        (self.root / "schema.json").write_text(json.dumps(layout_document()), encoding="utf-8")
        (self.root / "bindings.json").write_text(json.dumps(bindings), encoding="utf-8")

    def run_mode(self, mode: str, out: Path | None = None) -> list[str]:
        return generate.run(mode=mode, schema=self.root / "schema.json", bindings=self.root / "bindings.json",
                            repo_root=self.root, out=out if out is not None else self.out)

    def test_out_is_flat_because_swiftpm_compiles_only_the_files_directly_in_it(self) -> None:
        """A prebuild command's outputFilesDirectory is read one level deep: a file in a subfolder is never
        compiled (spike compile e7acd234: every generated Layout type was missing)."""
        self.run_mode("out")
        self.assertEqual([p.name for p in self.out.iterdir() if p.is_dir()], [])
        self.assertEqual(
            sorted(p.name for p in self.out.iterdir()),
            sorted(Path(relative).name for relative in rendered()),
        )

    def test_out_writes_every_file_and_a_second_run_changes_nothing(self) -> None:
        self.assertEqual(self.run_mode("out"), [])
        written = sorted(p.name for p in self.out.rglob("*.swift"))
        self.assertEqual(written, sorted(Path(relative).name for relative in rendered()))
        stamps = {p: p.stat().st_mtime_ns for p in self.out.rglob("*.swift")}
        self.run_mode("out")
        self.assertEqual(stamps, {p: p.stat().st_mtime_ns for p in self.out.rglob("*.swift")})

    def test_out_restores_an_edited_file_and_deletes_a_stale_one(self) -> None:
        self.run_mode("out")
        edited = self.out / "SwapPaneRequest.generated.swift"
        edited.write_text(edited.read_text(encoding="utf-8") + "// edit\n", encoding="utf-8")
        stale = self.out / "Old" / "OldRequest.generated.swift"
        stale.parent.mkdir(parents=True)
        stale.write_text(HEADER_MARK + "\n", encoding="utf-8")
        self.run_mode("out")
        self.assertEqual(edited.read_text(encoding="utf-8"), rendered()["Layout/SwapPaneRequest.generated.swift"])
        self.assertFalse(stale.exists())
        self.assertFalse(stale.parent.exists())

    def test_out_never_writes_where_swiftpm_compiles_sources(self) -> None:
        for out in (self.sources / "Generated", self.sources, self.root / "Other" / "Sources" / "X"):
            with self.subTest(out=out):
                with self.assertRaises(BindingError):
                    self.run_mode("out", out)
                self.assertEqual(list(out.rglob("*.generated.swift")) if out.exists() else [], [])

    def test_a_sources_root_outside_the_repository_is_refused(self) -> None:
        for root in ("/abs/Sources", "../Sources", "Sources/../../X", ""):
            with self.subTest(root=root):
                bindings = layout_bindings()
                bindings["sources_root"] = root
                self.write_inputs(bindings)
                with self.assertRaises(BindingError):
                    self.run_mode("check")

    def test_a_hand_written_file_at_a_generated_path_is_never_replaced(self) -> None:
        path = self.out / "SwapPaneRequest.generated.swift"
        path.parent.mkdir(parents=True)
        path.write_text("// hand-written\n", encoding="utf-8")
        with self.assertRaises(BindingError):
            self.run_mode("out")
        self.assertEqual(path.read_text(encoding="utf-8"), "// hand-written\n")

    def test_a_generated_file_of_another_generator_is_left_alone(self) -> None:
        self.run_mode("out")
        other = self.out / "Other.generated.swift"
        other.write_text("// GENERATED by another tool\n", encoding="utf-8")
        self.run_mode("out")
        self.assertTrue(other.exists())

    def test_check_passes_and_writes_nothing_when_no_type_is_also_hand_written(self) -> None:
        (self.sources / "SwapPaneRequest+Target.swift").write_text(
            "public enum SwapTarget {}\nextension SwapPaneRequest {}\n", encoding="utf-8")
        self.assertEqual(self.run_mode("check"), [])
        self.assertFalse(self.out.exists())

    def test_check_refuses_a_generated_type_that_is_still_hand_written(self) -> None:
        (self.sources / "Layout").mkdir()
        (self.sources / "Layout" / "ZoomPane.swift").write_text(
            "public struct ZoomPaneRequest: DaemonRequest {}\n", encoding="utf-8")
        (self.sources / "Layout" / "Direction.swift").write_text(
            "@frozen public enum PaneDirection: String { case up }\n", encoding="utf-8")
        problems = self.run_mode("check")
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("ZoomPaneRequest is generated" in p and "ZoomPane.swift" in p for p in problems))
        self.assertTrue(any("PaneDirection is generated" in p for p in problems))

    def test_check_fails_when_a_family_cannot_generate(self) -> None:
        bindings = layout_bindings()
        del bindings["types"]["RowHeight"]
        self.write_inputs(bindings)
        with self.assertRaises(BindingError):
            self.run_mode("check")


class CommandLineTests(unittest.TestCase):
    def test_write_is_gone_and_out_or_check_is_required(self) -> None:
        for argv in ([], ["--write"]):
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit) as raised, \
                        mock.patch("sys.stderr", new_callable=io.StringIO):
                    generate.main(argv)
                self.assertEqual(raised.exception.code, 2)

    def test_the_sdk_generator_only_ever_checks_the_swift_step(self) -> None:
        from codegen import generate as sdk_generate

        for mode in ("--check", "--write"):
            with self.subTest(mode=mode), mock.patch.object(sdk_generate, "run_generation", return_value=()), \
                    mock.patch("codegen.page_router.main", return_value=0), \
                    mock.patch("codegen.swift_app.generate.main", return_value=0) as swift_main:
                self.assertEqual(sdk_generate.main([mode]), 0)
                swift_main.assert_called_once_with(["--check"])


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
        self.assertTrue(generate.sources_root(REPO, bindings).is_dir())
        files = render(load_ir(generate.DEFAULT_SCHEMA), bindings)
        self.assertEqual(len(files), sum(
            len(family.get("enums", {})) + len(family.get("requests", {}))
            for family in bindings.get("families", {}).values()
        ))
        self.assertIn("Layout/SetColumnWidthRequest.generated.swift", files)

    def test_the_repository_passes_its_own_check(self) -> None:
        """No generated type is still declared by hand in CmuxNextDaemon (the build would fail to compile)."""
        self.assertEqual(
            generate.run(mode="check", schema=generate.DEFAULT_SCHEMA, bindings=generate.DEFAULT_BINDINGS,
                         repo_root=REPO),
            [],
        )

if __name__ == "__main__":
    unittest.main()
