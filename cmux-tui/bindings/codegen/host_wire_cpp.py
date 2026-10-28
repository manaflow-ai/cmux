#!/usr/bin/env python3
"""Build the Chromium host wire's C++ codec from cmux-tui/spec/chromium-host-wire.json.

Writes two headers into --output-dir, at build time (task p05-ipc-181; nothing it writes is
in git, scripts/ci/generated-files.json `chromium-host-wire-cpp`):

  chromium_host_wire.generated.h         kHeaderSize, kMaxPayload, the constants, enum Kind,
                                         struct Header, Encode and Decode, in the schema's
                                         namespace. ChromiumHost/src/chromium_host_wire.h
                                         includes it and keeps the hand-written rest.
  chromium_host_wire_golden.generated.h  kGoldenFrames: the schema's golden frames, which
                                         chromium_host_wire_test.cpp checks the codec against
                                         (ChromiumHostFrameTests checks the Swift codec against
                                         the same file).

Every compile of a file that includes chromium_host_wire.h runs this first and adds
-I<output-dir> (scripts/cmux-next/lib/host-wire.sh). The Swift side of the same schema is
CmuxNextWireGen's HostWireEmitter. The SDK's C++ emitter (emit_cpp.py) is a different wire
(cmux-tui's JSON protocol); this one runs on the macOS system Python, which the SDK IR does not.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path
from typing import List

if __package__ in (None, ""):
    # As a script, beside host_wire.py: the codegen package's __init__ imports the SDK IR.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from host_wire import Field, HostWire, HostWireError, cpp_name, load, type_range
else:
    from .host_wire import Field, HostWire, HostWireError, cpp_name, load, type_range

WIRE_HEADER = "chromium_host_wire.generated.h"
GOLDEN_HEADER = "chromium_host_wire_golden.generated.h"
DEFAULT_SCHEMA = Path(__file__).resolve().parents[2] / "spec" / "chromium-host-wire.json"
CPP_TYPES = {
    "u8": "uint8_t", "u16": "uint16_t", "u32": "uint32_t", "u64": "uint64_t",
    "i8": "int8_t", "i16": "int16_t", "i32": "int32_t", "i64": "int64_t",
}
BANNER = (
    "// Built by cmux-tui/bindings/codegen/host_wire_cpp.py from cmux-tui/spec/chromium-host-wire.json\n"
    "// at build time; not in git (task p05-ipc-181). Do not edit: change the schema.\n"
)


def literal(type_name: str, value: int) -> str:
    """A C++ literal of `value` with the type's suffix; the minimum of a signed type spelled so it parses."""
    low, _ = type_range(type_name)
    if value == low and value < 0:
        return f"({value + 1} - 1)"
    unsigned = type_name.startswith("u")
    wide = type_name in ("u64", "i64")
    if unsigned:
        text = f"0x{value:x}" if value > 0xFFFF else str(value)
        return text + ("ull" if wide else "u")
    return str(value) + ("ll" if wide else "")


def comments(lines, indent: str = "") -> List[str]:
    return [f"{indent}// {line}".rstrip() for line in lines]


def unsigned_of(f: Field) -> str:
    return CPP_TYPES["u" + f.type[1:]]


def wire_header(wire: HostWire) -> str:
    out: List[str] = [BANNER.rstrip("\n"), "// The hand-written rest of the wire is ChromiumHost/src/chromium_host_wire.h.",
                      "#pragma once", "", "#include <cstddef>", "#include <cstdint>", "",
                      f"namespace {wire.cpp_namespace} {{", ""]
    out += ["// The header every frame starts with, in bytes.",
            f"inline constexpr size_t kHeaderSize = {wire.header_size};",
            "// Longer payloads end the connection.",
            f"inline constexpr uint32_t kMaxPayload = {literal('u32', wire.max_payload)};"]
    for c in wire.constants:
        out += comments(c.doc)
        out.append(f"inline constexpr {CPP_TYPES[c.type]} {cpp_name(c.name)} = {literal(c.type, c.value)};")
    out += ["", "enum Kind : uint32_t {"]
    direction = None
    for k in wire.kinds:
        if k.direction != direction:
            direction = k.direction
            out.append("  // cmux -> host" if direction == "to_host" else "  // host -> cmux")
        out += comments(k.doc, "  ")
        out.append(f"  {cpp_name(k.name)} = {k.value},")
    out += ["};", "", "struct Header {"]
    for f in wire.fields:
        out += comments(f.doc, "  ")
        if f.count > 1:
            zeros = ", ".join(["0"] * f.count)
            out.append(f"  {CPP_TYPES[f.type]} {f.name}[{f.count}] = {{{zeros}}};")
        else:
            out.append(f"  {CPP_TYPES[f.type]} {f.name} = 0;")
    out += ["};", "",
            "namespace detail {",
            "template <typename T>",
            "inline void Put(uint8_t* out, size_t offset, T value) {",
            "  for (size_t i = 0; i < sizeof(T); ++i) out[offset + i] = static_cast<uint8_t>(static_cast<uint64_t>(value) >> (8 * i));",
            "}",
            "template <typename T>",
            "inline T Get(const uint8_t* in, size_t offset) {",
            "  uint64_t value = 0;",
            "  for (size_t i = 0; i < sizeof(T); ++i) value |= static_cast<uint64_t>(in[offset + i]) << (8 * i);",
            "  return static_cast<T>(value);",
            "}",
            "}  // namespace detail",
            "",
            "inline void Encode(const Header& h, uint8_t out[kHeaderSize]) {",
            "  using detail::Put;"]
    for f in wire.fields:
        unsigned = unsigned_of(f)
        if f.count > 1:
            value = f"static_cast<{unsigned}>(h.{f.name}[i])" if f.signed else f"h.{f.name}[i]"
            out.append(f"  for (size_t i = 0; i < {f.count}; ++i) Put<{unsigned}>(out, {f.offset} + {f.size} * i, {value});")
        else:
            value = f"static_cast<{unsigned}>(h.{f.name})" if f.signed else f"h.{f.name}"
            out.append(f"  Put<{unsigned}>(out, {f.offset}, {value});")
    length = wire.field("payload_length").name
    out += ["}", "",
            "// False when the header announces a payload longer than kMaxPayload.",
            "inline bool Decode(const uint8_t in[kHeaderSize], Header* h) {",
            "  using detail::Get;"]
    for f in wire.fields:
        unsigned = unsigned_of(f)
        if f.count > 1:
            read = f"Get<{unsigned}>(in, {f.offset} + {f.size} * i)"
            read = f"static_cast<{CPP_TYPES[f.type]}>({read})" if f.signed else read
            out.append(f"  for (size_t i = 0; i < {f.count}; ++i) h->{f.name}[i] = {read};")
        else:
            read = f"Get<{unsigned}>(in, {f.offset})"
            read = f"static_cast<{CPP_TYPES[f.type]}>({read})" if f.signed else read
            out.append(f"  h->{f.name} = {read};")
    out += [f"  return h->{length} <= kMaxPayload;", "}", "",
            f"}}  // namespace {wire.cpp_namespace}", ""]
    return "\n".join(out)


def c_string(data: bytes) -> str:
    out = []
    for byte in data:
        char = chr(byte)
        if char in '"\\?':
            out.append("\\" + char)
        elif 0x20 <= byte < 0x7F:
            out.append(char)
        else:
            out.append(f"\\{byte:03o}")
    return '"' + "".join(out) + '"'


def golden_header(wire: HostWire) -> str:
    out: List[str] = [BANNER.rstrip("\n"), "#pragma once", "", "#include <cstddef>", "",
                      f'#include "{WIRE_HEADER}"', "", f"namespace {wire.cpp_namespace} {{", "",
                      "// A frame both codecs encode as `hex` (the header) and `payload` after it.",
                      "struct GoldenFrame {", "  const char* name;", "  Header header;", "  const char* payload;",
                      "  const char* hex;", "};", "",
                      "inline const GoldenFrame kGoldenFrames[] = {"]
    for g in wire.golden:
        values = []
        for f in wire.fields:
            value = g.header[f.name]
            if f.count > 1:
                values.append("{" + ", ".join(literal(f.type, v) for v in value) + "}")
            else:
                values.append(literal(f.type, value))
        out += comments([g.doc] if g.doc else [], "  ")
        out.append(f'  {{"{g.name}", Header{{{", ".join(values)}}}, {c_string(g.payload)}, "{g.hex}"}},')
    out += ["};",
            f"inline constexpr size_t kGoldenFrameCount = {len(wire.golden)};", "",
            f"}}  // namespace {wire.cpp_namespace}", ""]
    return "\n".join(out)


def write(path: Path, text: str) -> None:
    """Writes atomically, so a compile running beside it never reads half a header."""
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        wire = load(args.schema)
    except HostWireError as error:
        print(f"host_wire_cpp.py: {error}", file=sys.stderr)
        return 1
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write(args.output_dir / WIRE_HEADER, wire_header(wire))
    write(args.output_dir / GOLDEN_HEADER, golden_header(wire))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
