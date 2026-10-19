"""Behavior tests for the base::Value codec backend (`generate.py --cpp-value`).

The fixture schema in `fixtures/cpp_value/` covers every IR construct the
browser codec maps: an alias, an opaque value, enums with and without a
fallback, a recursive tagged union, an untagged union, maps, arrays, inline
objects and enums, field aliases, extra properties, literals, and one command,
one type and one event outside the allowlist.

Regenerate the goldens after an intended change with
`CMUX_UPDATE_CPP_VALUE_GOLDENS=1` and review the diff. The C++ itself compiles
and round-trips in the Chromium tree (cmux-browser
`//third_party/cmux_tui_spec:cmux_daemon_types_unittests`), not here.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from codegen.emit_cpp_value import (
    ALLOWLIST_SCHEMA,
    HEADER_NAME,
    OUTPUT_NAMES,
    SOURCE_NAME,
    emit,
    load_allowlist,
    parse_allowlist,
)
from codegen.ir import load_ir, load_ir_document
from codegen.writer import GenerationError

CODEGEN = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "cpp_value"
FIXTURE_SCHEMA = FIXTURES / "sdk-schema.json"
FIXTURE_ALLOWLIST = FIXTURES / "allowlist.json"
GOLDEN = FIXTURES / "expected"
LIVE_SCHEMA = CODEGEN.parents[1] / "spec" / "sdk-schema.json"
UPDATE_GOLDENS = os.environ.get("CMUX_UPDATE_CPP_VALUE_GOLDENS") == "1"


def _fixture_document() -> dict[str, Any]:
    return json.loads(FIXTURE_SCHEMA.read_text(encoding="utf-8"))


def _allowlist(commands: list[str], events: list[str]) -> Any:
    return parse_allowlist(
        {"schema": ALLOWLIST_SCHEMA, "commands": commands, "events": events}
    )


def _text(files: dict[str, bytes]) -> str:
    return "\n".join(files[name].decode("utf-8") for name in OUTPUT_NAMES)


def _reversed_order(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _reversed_order(value[key]) for key in reversed(list(value))}
    if isinstance(value, list):
        return [_reversed_order(item) for item in value]
    return value


class GoldenTests(unittest.TestCase):
    def test_fixture_output_matches_the_goldens(self) -> None:
        files = emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST))
        if UPDATE_GOLDENS:
            GOLDEN.mkdir(parents=True, exist_ok=True)
            for name in OUTPUT_NAMES:
                (GOLDEN / name).write_bytes(files[name])
            self.skipTest("goldens rewritten")
        for name in OUTPUT_NAMES:
            with self.subTest(file=name):
                self.assertEqual(
                    files[name].decode("utf-8"),
                    (GOLDEN / name).read_text(encoding="utf-8"),
                    "regenerate with CMUX_UPDATE_CPP_VALUE_GOLDENS=1 and review",
                )

    def test_command_line_writes_the_goldens_and_check_detects_drift(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            out = Path(raw_directory) / "gen"
            base = [
                sys.executable,
                str(CODEGEN / "generate.py"),
                "--cpp-value",
                "--schema",
                str(FIXTURE_SCHEMA),
                "--allowlist",
                str(FIXTURE_ALLOWLIST),
                "--out",
                str(out),
            ]
            written = subprocess.run(base, capture_output=True, text=True, check=False)
            self.assertEqual(written.returncode, 0, written.stderr)
            for name in OUTPUT_NAMES:
                self.assertEqual((out / name).read_bytes(), (GOLDEN / name).read_bytes())

            checked = subprocess.run(
                [*base, "--check"], capture_output=True, text=True, check=False
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)

            (out / SOURCE_NAME).write_text("// edited\n", encoding="utf-8")
            drifted = subprocess.run(
                [*base, "--check"], capture_output=True, text=True, check=False
            )
            self.assertEqual(drifted.returncode, 1)
            self.assertIn("stale", drifted.stderr)
            self.assertIn(SOURCE_NAME, drifted.stderr)

    def test_command_line_rejects_cpp_value_without_its_inputs(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CODEGEN / "generate.py"), "--cpp-value"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--allowlist", result.stderr)


class ClosureTests(unittest.TestCase):
    def test_only_the_type_closure_of_the_allowlist_is_emitted(self) -> None:
        text = _text(emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST)))
        for absent in ("Unused", "NotListed", "unused-command", "not-listed"):
            self.assertNotIn(absent, text)
        for present in (
            "struct ReportFocusParams {",
            'inline constexpr std::string_view kReportFocusCapability = "client-focus-v1";',
            "inline constexpr int kReportFocusSince = 12;",
            "using ReportFocusResult = EmptyResult;",
            "using ListWorkspacesResult = std::vector<Workspace>;",
            "struct WorkspaceInfoResult {",
            "using Event = std::variant<UnknownEvent, TabClosedEvent, WorkspaceAddedEvent>;",
        ):
            self.assertIn(present, text)

    def test_a_smaller_allowlist_drops_types_it_does_not_reach(self) -> None:
        text = _text(
            emit(load_ir(FIXTURE_SCHEMA), _allowlist(["report-focus"], ["tab-closed"]))
        )
        self.assertIn("struct ReportFocusParams {", text)
        self.assertIn("struct TabClosedEvent {", text)
        for absent in ("Workspace", "Layout", "Pane", "Settings", "DeviceKind"):
            self.assertNotIn(absent, text)

    def test_params_get_encoders_and_results_get_decoders_only(self) -> None:
        source = emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST))[
            SOURCE_NAME
        ].decode("utf-8")
        self.assertIn("base::DictValue WriteObject(const ReportFocusParams& in) {", source)
        self.assertNotIn("ReportFocusParams& out", source)
        self.assertIn("DecodeContext& context, Workspace& out) {", source)
        self.assertNotIn("WriteObject(const Workspace& in)", source)
        # DeviceKind is both a parameter and a result field.
        self.assertIn("base::Value WriteModel(const DeviceKind& in) {", source)
        self.assertIn("DeviceKind& out) {", source)

    def test_a_type_that_contains_itself_is_held_by_pointer(self) -> None:
        header = emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST))[
            HEADER_NAME
        ].decode("utf-8")
        self.assertIn("  std::unique_ptr<Layout> a;\n  std::unique_ptr<Layout> b;", header)
        self.assertIn("  std::variant<LayoutLeaf, LayoutSplit> value;", header)
        self.assertLess(header.index("struct LayoutSplit {"), header.index("struct Layout {"))
        # An array item stays by value: std::vector allows an incomplete type.
        self.assertIn("  std::vector<Pane> panes;", header)

    def test_output_does_not_depend_on_schema_key_order(self) -> None:
        allowlist = load_allowlist(FIXTURE_ALLOWLIST)
        expected = emit(load_ir_document(_fixture_document()), allowlist)
        shuffled = emit(
            load_ir_document(_reversed_order(_fixture_document())), allowlist
        )
        self.assertEqual(expected, shuffled)


class EnumAndNumberRuleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.files = emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST))
        self.header = self.files[HEADER_NAME].decode("utf-8")
        self.source = self.files[SOURCE_NAME].decode("utf-8")

    def test_every_enum_has_k_unknown_and_unknown_strings_use_the_fallback(self) -> None:
        self.assertIn("enum class SplitDirection {\n  kUnknown,", self.header)
        # DeviceKind names "unknown" as its fallback: the wire value and the
        # fallback are both kUnknown.
        self.assertIn("enum class DeviceKind {\n  kUnknown,\n  kMac,", self.header)
        self.assertIn('  if (*text == "unknown") {\n    out = DeviceKind::kUnknown;', self.source)
        self.assertIn(
            '  out = SplitDirection::kUnknown;\n  return true;\n}', self.source
        )

    def test_integers_accept_only_exact_doubles_below_2_pow_53(self) -> None:
        self.assertIn("constexpr double kMaxExactInteger = 9007199254740992.0;", self.source)
        self.assertIn("std::trunc(number) != number", self.source)
        # 2^53 + 1 reads as 2^53, so 2^53 itself is refused on decode, and
        # an encode at or above it is a CHECK failure, never a rounded id.
        self.assertIn("std::fabs(number) >= kMaxExactInteger", self.source)
        self.assertIn("CHECK_LT(std::fabs(number), kMaxExactInteger);", self.source)
        self.assertIn("base::IsValueInRangeForNumericType<T>(wide)", self.source)

    def test_missing_required_fields_fail_with_their_path(self) -> None:
        self.assertIn('const size_t mark = PushField(context, "id");', self.source)
        self.assertIn('return Fail(context, "missing required field");', self.source)
        self.assertIn("const size_t mark = PushIndex(context, index);", self.source)
        self.assertIn('context.path = "result";', self.source)
        self.assertIn('field = dict.Find("clientId");', self.source)


class PresenceTests(unittest.TestCase):
    def setUp(self) -> None:
        files = emit(load_ir(FIXTURE_SCHEMA), load_allowlist(FIXTURE_ALLOWLIST))
        self.header = files[HEADER_NAME].decode("utf-8")
        self.source = files[SOURCE_NAME].decode("utf-8")

    def test_an_optional_nullable_request_field_has_three_states(self) -> None:
        # report-focus `tab` is optional and nullable: the daemon reads an
        # absent key and null differently (Option<Option<T>>).
        self.assertIn("  OptionalNullable<uint64_t> tab;", self.header)
        self.assertIn(
            '  if (in.tab.value) {\n    dict.Set("tab", WriteValue(*in.tab.value));\n'
            '  } else if (in.tab.is_null) {\n    dict.Set("tab", base::Value());\n  }',
            self.source,
        )

    def test_an_optional_nullable_result_field_stays_std_optional(self) -> None:
        self.assertIn("  std::optional<std::string> client_id;", self.header)

    def test_wire_names_that_map_to_one_member_are_rejected(self) -> None:
        document = _fixture_document()
        fields = document["commands"]["report-focus"]["request"]["fields"]
        fields["client-id"] = copy.deepcopy(fields["client_id"])
        with self.assertRaisesRegex(GenerationError, "client_id"):
            emit(load_ir_document(document), _allowlist(["report-focus"], []))


class AllowlistTests(unittest.TestCase):
    def test_rejects_malformed_allowlists(self) -> None:
        cases = {
            "wrong schema": {"schema": "v0", "commands": [], "events": []},
            "unsorted": {
                "schema": ALLOWLIST_SCHEMA,
                "commands": ["workspace-info", "report-focus"],
                "events": [],
            },
            "duplicate": {
                "schema": ALLOWLIST_SCHEMA,
                "commands": ["report-focus", "report-focus"],
                "events": [],
            },
            "not a list": {"schema": ALLOWLIST_SCHEMA, "commands": "x", "events": []},
            "unknown key": {
                "schema": ALLOWLIST_SCHEMA,
                "commands": [],
                "events": [],
                "types": [],
            },
        }
        for label, document in cases.items():
            with self.subTest(case=label):
                with self.assertRaises(GenerationError):
                    parse_allowlist(copy.deepcopy(document))

    def test_rejects_names_that_the_spec_does_not_define(self) -> None:
        ir = load_ir(FIXTURE_SCHEMA)
        with self.assertRaisesRegex(GenerationError, "v2 resource operations"):
            emit(ir, _allowlist(["settings.set"], []))
        with self.assertRaisesRegex(GenerationError, "unknown event"):
            emit(ir, _allowlist([], ["no-such-event"]))


class LiveSpecTests(unittest.TestCase):
    def test_every_live_command_and_event_generates(self) -> None:
        ir = load_ir(LIVE_SCHEMA)
        files = emit(ir, _allowlist(sorted(ir.commands), sorted(ir.events)))
        header = files[HEADER_NAME].decode("utf-8")
        for present in (
            "struct ReportFocusParams {",
            'inline constexpr std::string_view kReportFocusCapability = "client-focus-v1";',
            "  std::unique_ptr<Layout> a;",
            "// An unknown string decodes to SizeDeviceKind::kUnknown.",
            "base::expected<Event, DecodeError> DecodeEventChecked(",
        ):
            self.assertIn(present, header)


if __name__ == "__main__":
    unittest.main()
