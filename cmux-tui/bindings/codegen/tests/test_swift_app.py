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



class IfTrueTests(unittest.TestCase):
    """`encode: if_true`: a flag the app sends only when true, so an older daemon sees the request it always saw."""

    def source(self, **override: Any) -> str:
        bindings = layout_bindings()
        request = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        request["order"] = ["split", "ratio", "confirm_close"]
        request["fields"] = {"confirm_close": {"encode": "if_true", **override}}
        return rendered(bindings=bindings)["Layout/SetSplitRatioRequest.generated.swift"]

    def test_if_true_is_a_plain_bool_false_by_default_encoded_only_when_true(self) -> None:
        source = self.source()
        self.assertIn("public var confirmClose: Bool\n", source)
        self.assertIn("confirmClose: Bool = false", source)
        self.assertIn("if confirmClose { try container.encode(true, forKey: .confirmClose) }", source)
        self.assertIn('case confirmClose = "confirm_close"', source)

    def test_if_true_says_false_for_a_daemon_without_the_capability(self) -> None:
        document = layout_document()
        document["commands"]["set-split-ratio"]["request"]["fields"]["confirm_close"]["capability"] = "x-v1"
        bindings = layout_bindings()
        request = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        request["fields"] = {"confirm_close": {"encode": "if_true"}}
        source = rendered(document, bindings)["Layout/SetSplitRatioRequest.generated.swift"]
        self.assertIn("leave it false for a daemon that does not serve it", source)

    def test_if_true_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases = {
            "not a boolean": ("transaction", {"encode": "if_true"}),
            "a required field": ("ratio", {"encode": "if_true"}),
            "with optional": ("confirm_close", {"encode": "if_true", "optional": True}),
            "with a type": ("confirm_close", {"encode": "if_true", "type": "Int"}),
            "with a true default": ("confirm_close", {"encode": "if_true", "default": "true"}),
        }
        for label, (wire, override) in cases.items():
            bindings = layout_bindings()
            bindings["families"]["Layout"]["requests"]["set-split-ratio"]["fields"] = {wire: override}
            with self.subTest(label), self.assertRaises(BindingError):
                rendered(bindings=bindings)

    def test_if_true_is_refused_on_a_field_whose_schema_default_is_not_false(self) -> None:
        document = layout_document()
        document["commands"]["set-split-ratio"]["request"]["fields"]["confirm_close"]["default"] = True
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["set-split-ratio"]["fields"] = {
            "confirm_close": {"encode": "if_true"}
        }
        with self.assertRaises(BindingError):
            rendered(document, bindings)


class SentWithTests(unittest.TestCase):
    """`with`: a field sent only when another is true or set, as the hand-written types left it off alone."""

    def source(self, **fields: Any) -> str:
        bindings = layout_bindings()
        request = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        request["order"] = ["split", "ratio", "confirm_close", "transaction"]
        request["fields"] = fields
        return rendered(bindings=bindings)["Layout/SetSplitRatioRequest.generated.swift"]

    def test_with_an_if_true_flag_sends_the_field_only_when_the_flag_is_true(self) -> None:
        source = self.source(confirm_close={"encode": "if_true"}, transaction={"with": "confirm_close"})
        self.assertIn(
            "if confirmClose { try container.encodeIfPresent(transaction, forKey: .transaction) }", source
        )
        self.assertIn("/// Sent only with `confirmClose`.\n    public var transaction:", source)

    def test_with_an_optional_sends_the_field_only_when_it_is_set(self) -> None:
        source = self.source(confirm_close={"with": "transaction"})
        self.assertIn(
            "if transaction != nil { try container.encodeIfPresent(confirmClose, forKey: .confirmClose) }", source
        )

    def test_with_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases = {
            "itself": {"transaction": {"with": "transaction"}},
            "a field the schema lacks": {"transaction": {"with": "nope"}},
            "on a required field": {"ratio": {"with": "transaction"}},
            "on an always encoded field": {"transaction": {"with": "confirm_close", "encode": "always"}},
            "gated by a required field": {"transaction": {"with": "ratio"}},
        }
        for name, fields in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(**fields)


class OneOfTests(unittest.TestCase):
    """`one_of`: a hand-written enum whose cases each carry one optional field; only the one it holds is sent."""

    def source(self, one_of: Any, order: list[str] | None = None, **fields: Any) -> str:
        document = layout_document()
        request = document["commands"]["set-split-ratio"]["request"]["fields"]
        request["pane"] = _field(ID, required=False, nullable=True)
        request["column"] = _field(ID, required=False, nullable=True)
        bindings = layout_bindings()
        binding = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        binding["order"] = order or ["split", "target", "ratio"]
        binding["one_of"] = one_of
        binding["fields"] = fields
        return rendered(document, bindings)["Layout/SetSplitRatioRequest.generated.swift"]

    def test_one_of_sends_the_field_of_the_case_it_holds(self) -> None:
        source = self.source({"target": {"type": "DropTarget", "cases": ["pane", "column"], "doc": ["Where."]}})
        self.assertIn("    /// Where.\n    public var target: DropTarget\n", source)
        self.assertIn("public init(split: SplitID, target: DropTarget, ratio: Double,", source)
        self.assertIn(
            "        switch target {\n"
            "        case .pane(let value): try container.encode(value, forKey: .pane)\n"
            "        case .column(let value): try container.encode(value, forKey: .column)\n"
            "        }\n",
            source,
        )
        self.assertIn("        case split\n        case pane\n        case column\n        case ratio\n", source)
        self.assertNotIn("public var pane", source)

    def test_one_of_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases = {
            "one case": ({"target": {"type": "T", "cases": ["pane"]}}, None, {}),
            "no type": ({"target": {"cases": ["pane", "column"]}}, None, {}),
            "a field the schema lacks": ({"target": {"type": "T", "cases": ["pane", "nope"]}}, None, {}),
            "a required case": ({"target": {"type": "T", "cases": ["pane", "split"]}}, ["target", "ratio"], {}),
            "an always encoded case": (
                {"target": {"type": "T", "cases": ["pane", "column"]}}, None, {"pane": {"encode": "always"}}
            ),
            "a case in order": ({"target": {"type": "T", "cases": ["pane", "column"]}}, ["split", "pane"], {}),
            "a case in two": (
                {"a": {"type": "T", "cases": ["pane", "column"]}, "b": {"type": "U", "cases": ["pane", "transaction"]}},
                ["split", "ratio"], {},
            ),
        }
        for name, (one_of, order, fields) in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(one_of, order, **fields)


class NestedObjectTests(unittest.TestCase):
    """`object`: a field whose schema type is an object becomes a struct nested in the request; `omit` drops
    optional schema fields the Swift type never sends, on the request or on the nested object."""

    PIN = {"doc": ["The pin."], "order": ["edge", "pinned"], "omit": ["size"], "fields": {"pinned": {"encode": "if_true"}}}

    def document(self) -> dict[str, Any]:
        document = layout_document()
        document["types"]["Pin"] = {
            "kind": "object",
            "fields": {
                "edge": _field({"kind": "ref", "name": "PaneDirection"}),
                "pinned": _field({"kind": "scalar", "name": "boolean"}, required=False, default=False),
                "size": _field({"kind": "scalar", "name": "uint32"}, required=False, nullable=True),
            },
            "additional_properties": False,
        }
        document["types"]["Bare"] = {"kind": "object", "fields": {}, "additional_properties": False}
        request = document["commands"]["set-split-ratio"]["request"]["fields"]
        request["pin"] = _field({"kind": "ref", "name": "Pin"}, required=False, nullable=True)
        request["bare"] = _field({"kind": "ref", "name": "Bare"}, required=False, nullable=True)
        request["respawn"] = _field({"kind": "scalar", "name": "boolean"}, required=False, default=False)
        return document

    def source(self, fields: dict[str, Any] | None = None, omit: list[str] | None = None,
               order: list[str] | None = None) -> str:
        bindings = layout_bindings()
        binding = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        binding["order"] = order or ["split", "ratio", "pin"]
        binding["omit"] = ["respawn", "bare"] if omit is None else omit
        binding["fields"] = {"pin": {"object": self.PIN}} if fields is None else fields
        return rendered(self.document(), bindings)["Layout/SetSplitRatioRequest.generated.swift"]

    def test_the_nested_struct_encodes_its_own_fields(self) -> None:
        source = self.source()
        self.assertIn("    public var pin: Pin?\n", source)
        self.assertIn("    /// The pin.\n    public struct Pin: Encodable, Sendable, Equatable {\n", source)
        self.assertIn("        public var edge: PaneDirection\n", source)
        self.assertIn("        public init(edge: PaneDirection, pinned: Bool = false) {\n", source)
        self.assertIn("        enum CodingKeys: String, CodingKey {\n            case edge\n            case pinned\n", source)
        self.assertIn("            if pinned { try container.encode(true, forKey: .pinned) }\n", source)
        self.assertIn("        try container.encodeIfPresent(pin, forKey: .pin)\n", source)
        self.assertEqual(source.count("{"), source.count("}"))
        self.assertNotIn("size", source)
        self.assertNotIn("respawn", source)

    def test_a_name_overrides_the_field_name(self) -> None:
        source = self.source({"pin": {"object": {"name": "Dock", "order": ["edge"], "omit": ["pinned", "size"]}}})
        self.assertIn("    public var pin: Dock?\n", source)
        self.assertIn("    public struct Dock: Encodable, Sendable, Equatable {\n", source)

    def test_object_and_omit_are_refused_where_they_cannot_keep_the_wire(self) -> None:
        def pin(**binding: Any) -> dict[str, Any]:
            return {"pin": {"object": {"order": ["edge", "pinned"], "omit": ["size"], **binding}}}

        cases: dict[str, tuple[dict[str, Any] | None, list[str] | None, list[str] | None]] = {
            "an object binding on a scalar": ({"ratio": {"object": {}}}, None, None),
            "a nested field the schema lacks": (pin(order=["edge", "nope"]), None, None),
            "omit of a required field": (pin(order=["pinned"], omit=["edge", "size"]), None, None),
            "omit of a field it binds": (pin(order=["edge", "pinned", "size"]), None, None),
            "omit twice": (pin(omit=["size", "size"]), None, None),
            "an unknown key": (pin(nope=1), None, None),
            "a bad name": (pin(name="not a name"), None, None),
            "a nested update": (pin(order=["edge", "size"], omit=["pinned"], fields={"size": {"update": True}}), None, None),
            "an object that sends nothing": ({"bare": {"object": {}}}, ["respawn", "pin"], ["split", "ratio", "bare"]),
            "request omit of a required field": (None, ["respawn", "bare", "split"], ["ratio", "pin"]),
            "request omit of a field in order": (None, ["respawn", "bare"], ["split", "ratio", "pin", "respawn"]),
        }
        for name, (fields, omit, order) in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(fields, omit, order)


class SpreadTests(unittest.TestCase):
    """`spread`: a request property of a hand-written type (the top-level `spreads`) that encodes some optional
    schema fields flat, as `SpawnOptions` does for the terminal-spawning requests."""

    SPREADS = {"Spawn": {"doc": ["The new terminal."], "fields": ["cwd", "cols", "env"], "default": "Spawn()"}}

    def document(self) -> dict[str, Any]:
        document = layout_document()
        request = document["commands"]["swap-pane"]["request"]["fields"]
        request["cwd"] = _field({"kind": "scalar", "name": "string"}, required=False, nullable=True)
        request["cols"] = _field({"kind": "scalar", "name": "uint16"}, required=False, nullable=True)
        return document

    def source(self, binding: dict[str, Any] | None = None, spreads: dict[str, Any] | None = None) -> str:
        bindings = layout_bindings()
        bindings["spreads"] = self.SPREADS if spreads is None else spreads
        swap = bindings["families"]["Layout"]["requests"]["swap-pane"]
        swap.update({"order": ["pane", "options", "dir", "target"], "spread": {"options": "Spawn"}})
        swap.update(binding or {})
        return rendered(self.document(), bindings)["Layout/SwapPaneRequest.generated.swift"]

    def test_the_spread_takes_its_fields_and_encodes_them_flat(self) -> None:
        source = self.source()
        self.assertIn("    /// The new terminal.\n    /// Carries this command's `cwd`, `cols`, encoded flat, each when set.\n"
                      "    public var options: Spawn\n", source)
        self.assertIn("    public init(pane: PaneID, options: Spawn = Spawn(), dir: PaneDirection? = nil,"
                      " target: PaneID? = nil) {\n", source)
        self.assertIn("        try container.encodeIfPresent(target, forKey: .target)\n        try options.encode(to: encoder)\n",
                      source)
        self.assertNotIn("case cwd", source)
        self.assertNotIn("case cols", source)
        self.assertEqual(source.count("{"), source.count("}"))

    def test_without_order_the_spread_comes_last(self) -> None:
        source = self.source({"order": ["pane", "dir", "target"]})
        self.assertIn("target: PaneID? = nil, options: Spawn = Spawn()) {\n", source)

    def test_a_spread_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases: dict[str, tuple[dict[str, Any], dict[str, Any] | None]] = {
            "a type the spreads lack": ({"spread": {"options": "Nope"}}, None),
            "a spread that sends none of the fields": ({}, {"Spawn": {"fields": ["env"], "default": "Spawn()"}}),
            "a required field": ({}, {"Spawn": {"fields": ["pane", "cwd"], "default": "Spawn()"}}),
            "a field the request also binds": ({"fields": {"cwd": {"type": "String"}}}, None),
            "a field the order also names": ({"order": ["pane", "options", "cwd"]}, None),
            "two spreads of one field": ({"spread": {"options": "Spawn", "more": "Spawn"}}, None),
            "a property a field already has": ({"spread": {"target": "Spawn"}, "order": ["pane", "dir"]}, None),
            "a spread with no default": ({}, {"Spawn": {"fields": ["cwd"]}}),
            "a spread field twice": ({}, {"Spawn": {"fields": ["cwd", "cwd"], "default": "Spawn()"}}),
            "an unknown spreads key": ({}, {"Spawn": {"fields": ["cwd"], "default": "Spawn()", "nope": 1}}),
        }
        for name, (binding, spreads) in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(binding, spreads)


class InitTests(unittest.TestCase):
    """Request `init`: parameters that are no property (`params`) and fields the init sets from Swift expressions
    on them (`set`), as `NewRemoteTerminalTabRequest(_ ref:size:)` fills its session and size fields."""

    INIT = {
        "params": {"size": {"type": "CellSize?", "default": "nil"}},
        "set": {"cols": "size?.cols", "rows": "size?.rows"},
    }

    def source(self, binding: dict[str, Any] | None = None) -> str:
        document = layout_document()
        request = document["commands"]["swap-pane"]["request"]["fields"]
        request["cols"] = _field({"kind": "scalar", "name": "uint16"}, required=False, nullable=True)
        request["rows"] = _field({"kind": "scalar", "name": "uint16"}, required=False, nullable=True)
        bindings = layout_bindings()
        swap = bindings["families"]["Layout"]["requests"]["swap-pane"]
        swap.update({"order": ["pane", "size", "dir", "target"], "init": self.INIT,
                     "fields": {**swap.get("fields", {}), "cols": {"type": "Int"}, "rows": {"type": "Int"}}})
        swap.update(binding or {})
        return rendered(document, bindings)["Layout/SwapPaneRequest.generated.swift"]

    def test_a_parameter_sets_the_fields_and_is_no_property(self) -> None:
        source = self.source()
        self.assertIn("    public init(pane: PaneID, size: CellSize? = nil, dir: PaneDirection? = nil,"
                      " target: PaneID? = nil) {\n", source)
        self.assertIn("        self.cols = size?.cols\n", source)
        self.assertIn("        self.rows = size?.rows\n", source)
        self.assertIn("    public var cols: Int?\n", source)
        self.assertIn("try container.encodeIfPresent(cols, forKey: .cols)", source)
        self.assertNotIn("var size", source)
        self.assertNotIn("case size", source)
        self.assertNotIn("size, forKey", source)
        self.assertEqual(source.count("{"), source.count("}"))

    def test_a_label_and_a_set_with_no_parameter(self) -> None:
        source = self.source({"order": ["size", "pane"], "init": {
            "params": {"size": {"type": "CellSize", "label": "_"}},
            "set": {"cols": "size.cols", "rows": "nil"},
        }})
        self.assertIn("    public init(_ size: CellSize, pane: PaneID, dir: PaneDirection? = nil, target: PaneID? = nil) {",
                      source)
        self.assertIn("        self.rows = nil\n", source)

    def test_an_init_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases: dict[str, dict[str, Any]] = {
            "an unknown init key": {"init": {**self.INIT, "nope": 1}},
            "an unknown parameter key": {"init": {**self.INIT, "params": {"size": {"type": "CellSize", "nope": 1}}}},
            "a parameter with no type": {"init": {**self.INIT, "params": {"size": {"default": "nil"}}}},
            "a parameter that is a keyword": {"init": {"params": {"self": {"type": "Int"}}, "set": {"cols": "self"}}},
            "a parameter no expression reads": {"init": {**self.INIT, "params": {"size": {"type": "CellSize?"},
                                                                               "more": {"type": "Int"}}}},
            "a parameter a field already names": {"order": ["pane", "dir"], "init": {
                "params": {"target": {"type": "Int"}}, "set": {"cols": "target"}}},
            "a set field the order names": {"order": ["pane", "size", "cols"]},
            "a set field the schema lacks": {"init": {**self.INIT, "set": {"nope": "size?.cols"}}},
            "a set expression that is empty": {"init": {**self.INIT, "set": {"cols": ""}}},
            "params with no set": {"init": {"params": self.INIT["params"]}},
        }
        for name, binding in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(binding)


class UngatedTests(unittest.TestCase):
    """Request `ungated`: a command the schema gates on a capability that the app sends without asking."""

    def source(self, binding: dict[str, Any], capability: str | None = "layout-v1") -> str:
        document = layout_document()
        if capability:
            document["commands"]["swap-pane"]["capability"] = capability
        bindings = layout_bindings()
        bindings["families"]["Layout"]["requests"]["swap-pane"].update(binding)
        return rendered(document, bindings)["Layout/SwapPaneRequest.generated.swift"]

    def test_the_schema_gate_is_emitted_by_default(self) -> None:
        self.assertIn('    public static let requiredCapability: String? = "layout-v1"\n', self.source({}))

    def test_ungated_drops_the_gate_and_says_why(self) -> None:
        source = self.source({"ungated": "an older daemon still swaps."})
        self.assertNotIn("requiredCapability", source)
        self.assertIn("/// The schema gates it on `layout-v1`; the app sends it without asking:\n"
                      "/// an older daemon still swaps.\n", source)

    def test_ungated_is_refused_without_a_reason_or_a_gate(self) -> None:
        for name, binding, capability in [
            ("an empty reason", {"ungated": " "}, "layout-v1"),
            ("a reason that is no string", {"ungated": True}, "layout-v1"),
            ("no schema gate", {"ungated": "why"}, None),
        ]:
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(binding, capability)


class ConstantTests(unittest.TestCase):
    """Field `constant`: a fixed value always sent (no property), or with `encode: if_true` sent when a Bool is true."""

    def source(self, fields: dict[str, Any], order: list[str] | None = None) -> str:
        document = layout_document()
        request = document["commands"]["swap-pane"]["request"]["fields"]
        request["detached"] = _field({"kind": "scalar", "name": "boolean"}, required=False)
        request["side"] = _field({"kind": "enum", "values": ["left", "right"]}, required=False, nullable=True)
        request["count"] = _field({"kind": "scalar", "name": "uint16"}, required=False, nullable=True)
        bindings = layout_bindings()
        swap = bindings["families"]["Layout"]["requests"]["swap-pane"]
        swap["fields"] = {**swap.get("fields", {}), **fields}
        swap["omit"] = [wire for wire in ("detached", "side", "count") if wire not in fields]
        if order is not None:
            swap["order"] = order
        return rendered(document, bindings)["Layout/SwapPaneRequest.generated.swift"]

    def test_an_always_sent_constant_makes_no_property(self) -> None:
        source = self.source({"detached": {"constant": True}})
        self.assertIn("        try container.encode(true, forKey: .detached)\n", source)
        self.assertIn("        case detached\n", source)
        self.assertNotIn("var detached", source)
        self.assertNotIn("detached:", source.split("public init(", 1)[1].split(")", 1)[0])

    def test_an_if_true_constant_is_a_bool_sending_its_value(self) -> None:
        source = self.source({"side": {"constant": "left", "encode": "if_true", "name": "left"}})
        self.assertIn("    public var left: Bool\n", source)
        self.assertIn("left: Bool = false", source)
        self.assertIn('        if left { try container.encode("left", forKey: .left) }\n', source)
        self.assertIn('        case left = "side"\n', source)

    def test_a_constant_is_refused_where_it_cannot_keep_the_wire(self) -> None:
        cases: dict[str, dict[str, Any]] = {
            "a value the enum lacks": {"side": {"constant": "up"}},
            "a string for a boolean": {"detached": {"constant": "yes"}},
            "a negative unsigned": {"count": {"constant": -1}},
            "a bool for an integer": {"count": {"constant": True}},
            "a type beside it": {"detached": {"constant": True, "type": "Bool"}},
            "an encode mode it cannot take": {"detached": {"constant": True, "encode": "if_present"}},
        }
        for name, fields in cases.items():
            with self.subTest(name), self.assertRaises(BindingError):
                self.source(fields)


class DecimalTests(unittest.TestCase):
    """`encode: decimal`: a UInt64 the wire carries as a decimal string."""

    def source(self, constraints: list[Any] | None = None, **override: Any) -> str:
        document = layout_document()
        document["commands"]["set-split-ratio"]["request"]["fields"]["revision"] = _field(
            {"kind": "scalar", "name": "string"}, required=False, nullable=True,
            constraints=[{"format": "decimal uint64"}] if constraints is None else constraints,
        )
        bindings = layout_bindings()
        request = bindings["families"]["Layout"]["requests"]["set-split-ratio"]
        request["fields"] = {"revision": {"encode": "decimal", **override}}
        return rendered(document, bindings)["Layout/SetSplitRatioRequest.generated.swift"]

    def test_decimal_is_a_uint64_sent_as_its_string(self) -> None:
        source = self.source()
        self.assertIn("public var revision: UInt64?\n", source)
        self.assertIn("try container.encodeIfPresent(revision.map(String.init), forKey: .revision)", source)

    def test_decimal_is_refused_without_the_schema_format(self) -> None:
        for name, (constraints, override) in {
            "no format": ([], {}),
            "with type": (None, {"type": "Int"}),
            "with optional": (None, {"optional": True}),
        }.items():
            with self.subTest(name), self.assertRaisesRegex(BindingError, "encode decimal"):
                self.source(constraints, **override)


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
def workspace_ref_document() -> dict[str, Any]:
    """A write command that targets a workspace by handle or key."""
    document = mutation_document()
    fields = document["commands"]["rename-pane"]["request"]["fields"]
    document["commands"]["rename-pane"]["request"]["fields"] = {
        "workspace": _field(ID, required=False, nullable=True),
        "key": _field({"kind": "scalar", "name": "string"}, required=False, nullable=True),
        **fields,
    }
    return document


class WorkspaceRefTests(unittest.TestCase):
    """`workspace_ref`: the schema's `workspace` and `key` become one `WorkspaceRef`, encoded flat."""

    def source(self, order: list[str] | None = None, document: dict[str, Any] | None = None, **binding: Any) -> str:
        bindings = mutation_bindings()
        request = bindings["families"]["Layout"]["requests"]["rename-pane"]
        request["workspace_ref"] = True
        if order is not None:
            request["order"] = order
        request.update(binding)
        document = document or workspace_ref_document()
        return rendered(document, bindings)["Layout/RenamePaneRequest.generated.swift"]

    def test_workspace_ref_is_one_required_parameter_where_order_puts_it(self) -> None:
        source = self.source(["workspace", "pane", "title", "index", "mutation"])
        self.assertIn("public var workspace: WorkspaceRef\n", source)
        self.assertIn("public init(workspace: WorkspaceRef, pane: PaneID,", source)
        self.assertNotIn("case key", source)
        self.assertNotIn("case workspace", source)
        encode = source[source.index("func encode"):]
        ref = encode.index("try WorkspaceRefFields(ref: workspace).encode(to: encoder)")
        self.assertLess(encode.index("forKey: .index"), ref)
        self.assertLess(ref, encode.index("try MutationFields(identity: mutation)"))

    def test_workspace_ref_left_out_of_order_comes_after_the_fields_before_mutation(self) -> None:
        source = self.source()
        self.assertIn("index: Int, workspace: WorkspaceRef, mutation: MutationIdentity? = nil)", source)

    def test_workspace_ref_is_refused_without_both_optional_fields(self) -> None:
        missing = workspace_ref_document()
        del missing["commands"]["rename-pane"]["request"]["fields"]["key"]
        required = workspace_ref_document()
        required["commands"]["rename-pane"]["request"]["fields"]["workspace"] = _field(ID)
        for name, document in {"no key": missing, "a required workspace": required}.items():
            with self.subTest(name), self.assertRaisesRegex(BindingError, "workspace_ref needs"):
                self.source(document=document)
        with self.assertRaisesRegex(BindingError, "owns the workspace and key"):
            self.source(fields={"key": {"type": "String"}})
        with self.assertRaisesRegex(BindingError, "workspace_ref is true or false"):
            self.source(workspace_ref="yes")


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

    def test_the_repository_passes_its_own_check(self) -> None:
        """No generated type is still declared by hand in CmuxNextDaemon (the build would fail to compile)."""
        self.assertEqual(
            generate.run(mode="check", schema=generate.DEFAULT_SCHEMA, bindings=generate.DEFAULT_BINDINGS,
                         repo_root=REPO),
            [],
        )

if __name__ == "__main__":
    unittest.main()
