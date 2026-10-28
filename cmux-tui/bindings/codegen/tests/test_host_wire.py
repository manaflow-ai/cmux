"""The Chromium host wire schema and its C++ codec (task p05-ipc-181).

cmux-tui/spec/chromium-host-wire.json describes the 64-byte frames between cmux and the
Chromium host app; host_wire.py checks it and host_wire_cpp.py builds the C++ codec from
it at build time. scripts/cmux-next/tests/chromium-host-wire.test.sh compiles that codec and
runs it on the golden frames; ChromiumHostFrameTests does the same for the Swift codec.
"""
from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from codegen.host_wire_cpp import GOLDEN_HEADER, WIRE_HEADER, golden_header, literal, wire_header
from codegen.host_wire import HostWireError, encode_header, load, parse

SPEC = Path(__file__).resolve().parents[3] / "spec" / "chromium-host-wire.json"
EMITTER = Path(__file__).resolve().parents[1] / "host_wire_cpp.py"


def document() -> dict:
    return json.loads(SPEC.read_text(encoding="utf-8"))


class HostWireSchemaTests(unittest.TestCase):
    def test_live_schema_lays_out_the_64_byte_header(self) -> None:
        wire = load(SPEC)
        self.assertEqual(wire.header_size, 64)
        self.assertEqual([(f.name, f.offset) for f in wire.fields],
                         [("kind", 0), ("payload", 4), ("v", 8), ("flags", 32), ("t0", 40), ("t1", 48),
                          ("ch", 56), ("unmod", 58), ("seq", 60)])
        self.assertEqual(wire.max_payload, 64 * 1024)
        self.assertEqual({k.name: k.value for k in wire.kinds}["inputPresented"], 110)
        self.assertGreaterEqual({g.name for g in wire.golden}, {"key", "wheel-gesture", "wheel-momentum", "input-presented"})

    def test_golden_frames_encode_as_their_hex(self) -> None:
        wire = load(SPEC)
        key = next(g for g in wire.golden if g.name == "key")
        self.assertEqual(encode_header(wire, key.header).hex(), key.hex)
        self.assertEqual(key.payload, b"abc")

    def refused(self, edit, path: str) -> None:
        doc = copy.deepcopy(document())
        edit(doc)
        with self.assertRaises(HostWireError) as caught:
            parse(doc)
        self.assertIn(f": {path}: ", str(caught.exception))

    def test_refuses_layouts_neither_codec_can_build(self) -> None:
        def size(doc):
            doc["header"]["size"] = 72

        def misaligned(doc):
            doc["header"]["fields"][6]["type"] = "u8"
            doc["header"]["fields"][7]["type"] = "u32"

        def two_kinds(doc):
            doc["header"]["fields"][1]["role"] = "kind"

        def taken_value(doc):
            doc["kinds"][1]["value"] = 1

        def keyword(doc):
            doc["header"]["fields"][8]["name"] = "default"

        def inexact(doc):
            doc["constants"][0]["value"] = 1 << 53

        def too_wide(doc):
            doc["constants"][0]["value"] = "0x100000000"

        def unknown_key(doc):
            doc["kinds"][0]["dir"] = "to_host"

        self.refused(size, "$.header")
        self.refused(misaligned, "$.header.fields[7]")
        self.refused(two_kinds, "$.header.fields")
        self.refused(taken_value, "$.kinds[1].value")
        self.refused(keyword, "$.header.fields[8].name")
        self.refused(inexact, "$.constants[0].value")
        self.refused(too_wide, "$.constants[0].value")
        self.refused(unknown_key, "$.kinds[0]")

    def test_refuses_a_golden_frame_that_disagrees_with_its_fields(self) -> None:
        def wrong_hex(doc):
            doc["golden"][0]["hex"] = "06" + doc["golden"][0]["hex"][2:]

        def wrong_length(doc):
            doc["golden"][0]["payload"] = "abcd"

        self.refused(wrong_hex, "$.golden[0].hex")
        self.refused(wrong_length, "$.golden[0].header.payload")


class HostWireCppTests(unittest.TestCase):
    def test_emits_the_codec_and_the_golden_table(self) -> None:
        wire = load(SPEC)
        header = wire_header(wire)
        for line in (
            "inline constexpr size_t kHeaderSize = 64;",
            "inline constexpr uint32_t kMaxPayload = 0x10000u;",
            "inline constexpr uint64_t kWheelPrecise = 0x8000000000000000ull;",
            "  kInputPresented = 110,",
            "  int32_t v[6] = {0, 0, 0, 0, 0, 0};",
            "  for (size_t i = 0; i < 6; ++i) Put<uint32_t>(out, 8 + 4 * i, static_cast<uint32_t>(h.v[i]));",
            "  h->seq = Get<uint32_t>(in, 60);",
            "  return h->payload <= kMaxPayload;",
        ):
            self.assertIn(line + "\n", header)
        golden = golden_header(wire)
        self.assertIn(f'#include "{WIRE_HEADER}"', golden)
        self.assertIn('{"key", Header{5u, 3u, {10, -2, 2147483647, 3, 4, -1}, 0x100000ull,', golden)

    def test_literals_parse_at_the_type_limits(self) -> None:
        self.assertEqual(literal("i32", -(1 << 31)), "(-2147483647 - 1)")
        self.assertEqual(literal("i64", -(1 << 63)), "(-9223372036854775807 - 1)")
        self.assertEqual(literal("u64", 7), "7ull")
        self.assertEqual(literal("u32", 0xDEADBEEF), "0xdeadbeefu")

    def test_the_build_path_writes_both_headers_the_same_every_run(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            outputs = []
            for run in ("a", "b"):
                out = Path(scratch) / run
                subprocess.run([sys.executable, "-I", str(EMITTER), "--schema", str(SPEC), "--output-dir", str(out)],
                               check=True)
                outputs.append({name: (out / name).read_text(encoding="utf-8") for name in (WIRE_HEADER, GOLDEN_HEADER)})
            self.assertEqual(outputs[0], outputs[1])

    def test_the_build_path_refuses_a_bad_schema_and_writes_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            doc = document()
            doc["header"]["size"] = 72
            bad = Path(scratch) / "bad.json"
            bad.write_text(json.dumps(doc), encoding="utf-8")
            out = Path(scratch) / "out"
            result = subprocess.run([sys.executable, "-I", str(EMITTER), "--schema", str(bad), "--output-dir", str(out)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("$.header: the fields fill 64 bytes, not size 72", result.stderr)
            self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
