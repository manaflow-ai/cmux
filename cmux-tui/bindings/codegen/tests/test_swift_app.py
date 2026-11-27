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

    def test_legacy_request_can_still_be_sent_without_its_advertised_capability(self) -> None:
        bindings = layout_bindings()
        request = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        request["allow_unadvertised_capability"] = "layout-undo-v1"
        self.assertNotIn("requiredCapability", rendered(bindings=bindings)["Layout/SetSplitRatioRequest.generated.swift"])

        request["allow_unadvertised_capability"] = "renamed-v2"
        with self.assertRaisesRegex(BindingError, "must name the command's schema capability"):
            rendered(bindings=bindings)

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



def mutation_document() -> dict[str, Any]:
    """A write command carrying the four mutation identity fields."""
    document = layout_document()
    optional = lambda name: _field({"kind": "scalar", "name": name}, required=False, nullable=True)  # noqa: E731
    document["commands"]["rename-pane"] = {
        "authority": "control",
        "since": 9,
        "capability": None,
        "request": {
            "kind": "object",
            "fields": {
                "pane": _field(ID),
                "title": optional("string"),
                "index": _field({"kind": "scalar", "name": "uint64"}),
                "origin": optional("string"),
                "mutation_id": optional("string"),
                "expected_generation": optional("uint64"),
                "expected_revision": optional("uint64"),
            },
            "additional_properties": False,
        },
        "result": {"kind": "ref", "name": "EmptyResult"},
        "stream": None,
        "constraints": [],
    }
    return document


def mutation_bindings(**fields: Any) -> dict[str, Any]:
    bindings = layout_bindings()
    bindings["families"]["Layout"]["requests"]["rename-pane"] = {
        "name": "RenamePaneRequest",
        "order": ["pane", "title", "index"],
        "mutation": True,
        "fields": fields or {"title": {"update": True}, "index": {"type": "Int"}},
    }
    return bindings


class FieldOverrideTests(unittest.TestCase):
    def source(self, **fields: Any) -> str:
        return rendered(mutation_document(), mutation_bindings(**fields))["Layout/RenamePaneRequest.generated.swift"]

    def test_mutation_folds_the_identity_fields_into_one_parameter_encoded_last(self) -> None:
        source = self.source()
        self.assertIn("public var mutation: MutationIdentity?", source)
        self.assertNotIn("mutationID", source)
        self.assertNotIn("case origin", source)
        self.assertIn("try MutationFields(identity: mutation).encode(to: encoder)", source)
        self.assertLess(source.index("forKey: .index"), source.index("MutationFields(identity"))

    def test_update_is_a_field_update_always_encoded(self) -> None:
        source = self.source()
        self.assertIn("public var title: FieldUpdate<String>", source)
        self.assertIn("title: FieldUpdate<String> = .unchanged", source)
        self.assertIn("try container.encode(title, forKey: .title)", source)

    def test_type_overrides_the_swift_type_and_keeps_the_wire_name(self) -> None:
        source = self.source()
        self.assertIn("public var index: Int", source)
        self.assertIn("case index\n", source)

    def test_optional_false_with_encode_always_makes_a_plain_property(self) -> None:
        source = self.source(title={"optional": False, "encode": "always", "type": "String", "default": '""'})
        self.assertIn("public var title: String", source)
        self.assertIn('title: String = ""', source)
        self.assertIn("try container.encode(title, forKey: .title)", source)

    def test_bad_overrides_are_refused(self) -> None:
        cases = {
            "update on a required field": {"index": {"update": True}},
            "unknown encode mode": {"title": {"encode": "sometimes"}},
            "update with optional": {"title": {"update": True, "optional": True}},
            "unknown key": {"title": {"colour": "red"}},
            "empty default": {"title": {"default": ""}},
        }
        for label, fields in cases.items():
            with self.subTest(label), self.assertRaises(BindingError):
                rendered(mutation_document(), mutation_bindings(**fields))

    def test_mutation_without_the_identity_fields_is_refused(self) -> None:
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"]["mutation"] = True
        with self.assertRaises(BindingError):
            rendered(bindings=bindings)
def read_bindings(objects: dict[str, Any]) -> dict[str, Any]:
    bindings = layout_bindings()
    bindings["families"]["Layout"]["objects"] = objects
    return bindings


class ReadTypeTests(unittest.TestCase):
    """`objects`: result and snapshot types the app decodes, generated from schema objects or command results."""

    def test_a_schema_object_becomes_a_decodable_struct_with_init_and_wire_keys(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {"type": "ZoomPaneResult", "doc": ["Zoom."]}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertIn("/// Zoom.\npublic struct ZoomState: Decodable, Sendable, Equatable {", source)
        self.assertIn("    public var zoomedPane: PaneID?\n", source)
        self.assertIn("public init(pane: PaneID, zoomed: Bool, zoomedPane: PaneID? = nil)", source)
        self.assertIn('case zoomedPane = "zoomed_pane"', source)
        self.assertNotIn("init(from decoder", source)

    def test_a_command_result_becomes_a_struct(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomResultCopy": {"result": "zoom-pane"}}))
        self.assertIn("public struct ZoomResultCopy:", files["Layout/ZoomResultCopy.generated.swift"])

    def test_a_default_decodes_leniently_and_defaults_the_init(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"default": "false"}}}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertIn("public var zoomed: Bool\n", source)
        self.assertIn("zoomed: Bool = false", source)
        self.assertIn("zoomed = try container.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false", source)
        self.assertIn("pane = try container.decode(PaneID.self, forKey: .pane)", source)

    def test_lenient_reads_a_malformed_value_as_missing(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"lenient": True, "default": "false"},
                                                 "zoomed_pane": {"lenient": True}}}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertIn(
            "zoomed = (((try? container.decodeIfPresent(Bool.self, forKey: .zoomed)) ?? nil)) ?? false", source)
        self.assertIn(
            "zoomedPane = ((try? container.decodeIfPresent(PaneID.self, forKey: .zoomedPane)) ?? nil)", source)

    def test_when_reads_a_field_only_under_its_condition(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed_pane": {"when": "zoomed", "lenient": True}}}}))
        self.assertIn(
            "zoomedPane = zoomed ? (((try? container.decodeIfPresent(PaneID.self, forKey: .zoomedPane)) ?? nil)) : nil",
            files["Layout/ZoomState.generated.swift"])

    def test_prefer_reads_another_key_first_and_falls_back(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "omit": ["zoomed_pane"],
            "fields": {"pane": {"prefer": "zoomed_pane", "optional": True}}}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertIn(
            "pane = try container.decodeIfPresent(PaneID.self, forKey: .zoomedPane)"
            " ?? container.decodeIfPresent(PaneID.self, forKey: .pane)", source)
        self.assertIn('case zoomedPane = "zoomed_pane"', source)
        self.assertNotIn("var zoomedPane", source)

    def test_optional_makes_a_required_field_optional(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"optional": True}}}}))
        self.assertIn("public var zoomed: Bool?\n", files["Layout/ZoomState.generated.swift"])

    def test_rename_type_override_order_and_conformances(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "conformances": ["Codable", "Sendable", "Hashable"],
            "order": ["zoomed", "pane"], "fields": {"zoomed_pane": {"name": "focus", "type": "String"}}}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertIn("public struct ZoomState: Codable, Sendable, Hashable {", source)
        self.assertLess(source.index("var zoomed:"), source.index("var pane:"))
        self.assertIn("public var focus: String?", source)
        self.assertIn('case focus = "zoomed_pane"', source)

    def test_omit_drops_a_field_and_extra_adds_an_app_only_property(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {
            "type": "ZoomPaneResult", "omit": ["zoomed"],
            "extra": {"selected": {"type": "Bool", "default": "false", "doc": ["App only."]}}}}))
        source = files["Layout/ZoomState.generated.swift"]
        self.assertNotIn("var zoomed:", source)
        self.assertIn("/// App only.\n    public var selected: Bool\n", source)
        self.assertNotIn("case selected", source)
        self.assertIn("selected = false", source)

    def test_without_init_no_memberwise_init_is_emitted(self) -> None:
        files = rendered(bindings=read_bindings({"ZoomState": {"type": "ZoomPaneResult", "init": False}}))
        self.assertNotIn("public init(pane:", files["Layout/ZoomState.generated.swift"])

    def test_a_generated_type_resolves_refs_to_its_schema_type(self) -> None:
        files = rendered(bindings=read_bindings({"RowHeightRecord": {
            "type": "RowHeight", "fields": {"row": {"type": "String"}}}}) | {"types": {}})
        self.assertIn("public struct RowHeightRecord", files["Layout/RowHeightRecord.generated.swift"])
        self.assertIn("[RowHeightRecord]", files["Layout/SetRowHeightsRequest.generated.swift"])

    def test_output_passes_the_hygiene_rules(self) -> None:
        bindings = read_bindings({"ZoomState": {"type": "ZoomPaneResult", "fields": {"zoomed": {"default": "false"}}}})
        self.assertEqual(rendered(bindings=bindings), rendered(bindings=bindings))
        source = rendered(bindings=bindings)["Layout/ZoomState.generated.swift"]
        self.assertFalse(re.search(r"[ \t]+$", source, re.M))
        self.assertTrue(source.endswith("}\n"))


class ReadTypeBindingErrorTests(unittest.TestCase):
    def assert_refused(self, message: str, objects: dict[str, Any], bindings: dict[str, Any] | None = None) -> None:
        with self.assertRaises(BindingError) as raised:
            rendered(bindings=bindings or read_bindings(objects))
        self.assertIn(message, str(raised.exception))

    def test_read_options_refuse_what_has_no_swift_shape(self) -> None:
        self.assert_refused("when needs an optional field", {"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"when": "true", "default": "false"}}}})
        self.assert_refused("lenient needs an optional field or a default", {"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"lenient": True}}}})
        self.assert_refused("omit it", {"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"pane": {"prefer": "zoomed_pane"}}}})
        self.assert_refused("which the schema does not have", {"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"pane": {"prefer": "nope"}}}})

    def test_write_only_encode_when_is_refused_for_read_types(self) -> None:
        self.assert_refused("unknown key", {"ZoomState": {
            "type": "ZoomPaneResult", "fields": {"zoomed": {"encode_when": "pane"}}}})

    def test_type_and_result_are_exclusive(self) -> None:
        self.assert_refused("exactly one of type", {"Z": {"type": "ZoomPaneResult", "result": "zoom-pane"}})
        self.assert_refused("exactly one of type", {"Z": {}})

    def test_an_unknown_type_or_command_is_refused(self) -> None:
        self.assert_refused("no object type Nope", {"Z": {"type": "Nope"}})
        self.assert_refused("no command nope", {"Z": {"result": "nope"}})

    def test_omitting_an_unknown_field_is_refused(self) -> None:
        self.assert_refused("omit names 'nope'", {"Z": {"type": "ZoomPaneResult", "omit": ["nope"]}})

    def test_omitting_a_required_field_of_an_encoded_type_is_refused(self) -> None:
        self.assert_refused("the schema requires", {"Z": {
            "type": "ZoomPaneResult", "conformances": ["Codable", "Sendable"], "omit": ["pane"]}})

    def test_an_extra_colliding_with_a_wire_field_or_missing_its_default_is_refused(self) -> None:
        self.assert_refused("the schema has this field", {"Z": {
            "type": "ZoomPaneResult", "extra": {"zoomed": {"type": "Bool", "default": "false"}}}})
        self.assert_refused("needs its type and default", {"Z": {
            "type": "ZoomPaneResult", "extra": {"selected": {"type": "Bool"}}}})

    def test_generating_and_binding_one_schema_type_is_refused(self) -> None:
        self.assert_refused("RowHeight", {"RowHeightRecord": {"type": "RowHeight"}})


def spawn_document() -> dict[str, Any]:
    """A spawning write command: spawn fields to flatten, a size, a flag sent only when true."""
    document = mutation_document()
    optional = lambda name: _field({"kind": "scalar", "name": name}, required=False, nullable=True)  # noqa: E731
    document["commands"]["spawn-pane"] = {
        "authority": "control",
        "since": 9,
        "capability": None,
        "request": {
            "kind": "object",
            "fields": {
                "pane": _field(ID),
                "cwd": optional("string"),
                "cols": optional("uint16"),
                "rows": optional("uint16"),
                "label": optional("string"),
                "before": _field({"kind": "scalar", "name": "boolean"}, required=False, default=False),
                "origin": optional("string"),
                "mutation_id": optional("string"),
            },
            "additional_properties": False,
        },
        "result": {"kind": "ref", "name": "EmptyResult"},
        "stream": None,
        "constraints": [],
    }
    return document


def spawn_bindings(**request: Any) -> dict[str, Any]:
    bindings = mutation_bindings()
    bindings["flatten"] = {
        "SpawnOptions": {"wire": ["cwd", "argv"], "encode": "try {value}.encode(to: encoder)"},
        "CellSize": {"wire": ["cols", "rows"], "encode": "try {value}.encode(to: encoder)"},
    }
    bindings["families"]["Layout"]["requests"]["spawn-pane"] = {
        "name": "SpawnPaneRequest",
        "protocol": "TerminalSpawningRequest",
        "order": ["pane", "options", "size", "before", "mutation"],
        "mutation": True,
        "flatten": {
            "options": {"type": "SpawnOptions", "default": "SpawnOptions()"},
            "size": {"type": "CellSize", "optional": True},
        },
        "fields": {"before": {"encode": "when_true"}},
        **request,
    }
    return bindings


class FlattenAndWhenTrueTests(unittest.TestCase):
    def source(self, **request: Any) -> str:
        return rendered(spawn_document(), spawn_bindings(**request))["Layout/SpawnPaneRequest.generated.swift"]

    def test_flatten_takes_its_wire_fields_and_encodes_the_value_flat(self) -> None:
        source = self.source()
        self.assertIn("public var options: SpawnOptions\n", source)
        self.assertIn("options: SpawnOptions = SpawnOptions()", source)
        self.assertIn("        try options.encode(to: encoder)\n", source)
        for wire in ("cwd", "cols", "rows"):
            self.assertNotIn(f"case {wire}", source)
        self.assertIn("case label", source)

    def test_an_optional_flatten_is_written_only_when_set(self) -> None:
        source = self.source()
        self.assertIn("public var size: CellSize?", source)
        self.assertIn("size: CellSize? = nil", source)
        self.assertIn("        if let size { try size.encode(to: encoder) }\n", source)

    def test_order_places_flattened_and_mutation_properties(self) -> None:
        self.assertIn(
            "public init(pane: PaneID, options: SpawnOptions = SpawnOptions(), size: CellSize? = nil,"
            " before: Bool = false, mutation: MutationIdentity? = nil, label: String? = nil)",
            self.source(),
        )

    def test_encode_writes_keyed_fields_then_flattened_values_then_the_mutation(self) -> None:
        source = self.source()
        self.assertLess(source.index("forKey: .label"), source.index("try options.encode"))
        self.assertLess(source.index("if let size"), source.index("MutationFields(identity"))

    def test_when_true_is_a_plain_bool_sent_only_as_true(self) -> None:
        source = self.source()
        self.assertIn("public var before: Bool\n", source)
        self.assertIn("before: Bool = false", source)
        self.assertIn("        if before { try container.encode(true, forKey: .before) }\n", source)

    def test_encode_when_gates_an_optional_field_on_a_prior_property(self) -> None:
        source = self.source(fields={"before": {"encode": "when_true"}, "label": {"encode_when": "before"}})
        self.assertIn("        if before { try container.encodeIfPresent(label, forKey: .label) }\n", source)

    def test_encode_when_requires_a_non_empty_string(self) -> None:
        with self.assertRaises(BindingError):
            self.source(fields={"before": {"encode": "when_true"}, "label": {"encode_when": ""}})

    def test_encode_when_cannot_gate_required_or_when_true_fields(self) -> None:
        for fields in (
            {"pane": {"encode_when": "before"}},
            {"before": {"encode": "when_true", "encode_when": "label"}},
        ):
            with self.subTest(fields), self.assertRaises(BindingError):
                self.source(fields=fields)

    def test_bad_flatten_and_when_true_bindings_are_refused(self) -> None:
        cases = {
            "unregistered type": {"flatten": {"options": {"type": "Nope"}}},
            "no wire field in the schema": {"flatten": {"options": {"type": "Other"}}},
            "unknown key": {"flatten": {"options": {"type": "SpawnOptions", "colour": "red"}}},
            "flatten named mutation": {"flatten": {"mutation": {"type": "SpawnOptions"}}},
            "when_true on a string": {"fields": {"before": {"encode": "when_true"}, "label": {"encode": "when_true"}}},
            "when_true with optional": {"fields": {"before": {"encode": "when_true", "optional": True}}},
        }
        for label, request in cases.items():
            bindings = spawn_bindings(**request)
            bindings["flatten"]["Other"] = {"wire": ["argv"], "encode": "try {value}.encode(to: encoder)"}
            with self.subTest(label), self.assertRaises(BindingError):
                rendered(spawn_document(), bindings)

    def test_a_flatten_may_not_take_a_required_field(self) -> None:
        bindings = spawn_bindings()
        bindings["flatten"]["SpawnOptions"]["wire"].append("pane")
        with self.assertRaises(BindingError):
            rendered(spawn_document(), bindings)

    def test_a_registry_entry_needs_wire_names_and_a_value_statement(self) -> None:
        for entry in ({"wire": [], "encode": "try {value}.encode(to: encoder)"}, {"wire": ["cwd"], "encode": "x"}):
            bindings = spawn_bindings()
            bindings["flatten"]["SpawnOptions"] = entry
            with self.subTest(entry), self.assertRaises(BindingError):
                rendered(spawn_document(), bindings)

    def test_flatten_values_cannot_share_a_wire_name_with_independent_remaining_fields(self) -> None:
        bindings = spawn_bindings()
        bindings["flatten"]["Other"] = {
            "wire": ["cols", "height"], "encode": "try {value}.encode(to: encoder)"
        }
        bindings["families"]["Layout"]["requests"]["spawn-pane"]["flatten"]["other"] = {"type": "Other"}
        with self.assertRaisesRegex(BindingError, "overlap.*cols"):
            rendered(spawn_document(), bindings)

    def test_flatten_overlap_is_rejected_even_when_the_shared_wire_is_absent_from_the_schema(self) -> None:
        bindings = spawn_bindings()
        bindings["flatten"]["Other"] = {
            "wire": ["argv", "height"], "encode": "try {value}.encode(to: encoder)"
        }
        bindings["families"]["Layout"]["requests"]["spawn-pane"]["flatten"]["other"] = {"type": "Other"}
        with self.assertRaisesRegex(BindingError, "overlap.*argv"):
            rendered(spawn_document(), bindings)

    def test_omit_rejects_unknown_and_required_fields(self) -> None:
        for omitted, message in ((["unknown"], "does not have"), (["pane"], "requires")):
            bindings = spawn_bindings(omit=omitted)
            with self.subTest(omitted), self.assertRaisesRegex(BindingError, message):
                rendered(spawn_document(), bindings)

    def test_omit_removes_an_optional_field(self) -> None:
        source = self.source(omit=["label"])
        self.assertNotIn("case label", source)
        self.assertNotIn("label: String?", source)

    def test_omit_rejects_fields_written_by_flatten_and_mutation(self) -> None:
        for omitted, message in ((["cols"], "flattened value"), (["origin"], "mutation")):
            bindings = spawn_bindings(omit=omitted)
            with self.subTest(omitted), self.assertRaisesRegex(BindingError, message):
                rendered(spawn_document(), bindings)


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

    def test_out_writes_every_file_and_a_second_run_changes_nothing(self) -> None:
        self.assertEqual(self.run_mode("out"), [])
        # Flat: SwiftPM compiles only the top level of a prebuild command's output folder.
        written = sorted(p.relative_to(self.out).as_posix() for p in self.out.rglob("*.swift"))
        self.assertEqual(written, sorted(Path(name).name for name in rendered()))
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
            len(family.get("enums", {})) + len(family.get("requests", {})) + len(family.get("objects", {}))
            for family in bindings.get("families", {}).values()
        ))
        self.assertIn("Layout/SetColumnWidthRequest.generated.swift", files)

    def test_create_terminal_omits_the_detached_selector_but_keeps_workspace(self) -> None:
        bindings = generate.load_bindings(generate.DEFAULT_BINDINGS)
        files = render(load_ir(generate.DEFAULT_SCHEMA), bindings)
        source = files["Creation/CreateTerminalRequest.generated.swift"]
        self.assertIn("public var workspace: WorkspaceRef", source)
        self.assertNotIn("detached", source)

    def test_the_repository_passes_its_own_check(self) -> None:
        """No generated type is still declared by hand in CmuxNextDaemon (the build would fail to compile)."""
        self.assertEqual(
            generate.run(mode="check", schema=generate.DEFAULT_SCHEMA, bindings=generate.DEFAULT_BINDINGS,
                         repo_root=REPO),
            [],
        )

if __name__ == "__main__":
    unittest.main()
