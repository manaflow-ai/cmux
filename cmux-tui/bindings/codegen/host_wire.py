"""The Chromium host wire schema (cmux-tui/spec/chromium-host-wire.json): load, check, encode.

The schema describes the 64-byte frames between cmux and the Chromium host app (task
p05-ipc-181). host_wire_cpp.py builds the C++ codec from it and CmuxNextWireGen's
HostWireEmitter the Swift one; both refuse the same schemas. `encode_header` is a third,
independent encoder: `load` checks every golden frame's hex against it, so a golden vector
that disagrees with its own fields fails before either side compiles.

Runs on the macOS system Python (3.9): build-chromium-host.sh calls it from an Xcode build
phase. So no SDK IR import (its dataclasses need 3.10) and no 3.10 syntax at run time.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# name: (bytes, signed)
INT_TYPES: Dict[str, Tuple[int, bool]] = {
    "u8": (1, False),
    "u16": (2, False),
    "u32": (4, False),
    "u64": (8, False),
    "i8": (1, True),
    "i16": (2, True),
    "i32": (4, True),
    "i64": (8, True),
}
ROLES = ("kind", "payload_length")
DIRECTIONS = ("to_host", "to_cmux")
NAME = re.compile(r"[a-z][A-Za-z0-9]*\Z")
GOLDEN_NAME = re.compile(r"[a-z][a-z0-9-]*\Z")
# Field names are used as written on both sides: none may be a Swift or C++ keyword.
KEYWORDS = frozenset(
    """
    alignas alignof and asm associatedtype auto bool break case catch char class const constexpr
    continue default defer delete deinit do double else enum explicit export extension extern
    fallthrough false fileprivate float for friend func goto guard if import in init inline int
    internal is let long mutable namespace new nil not nullptr operator or private protocol
    public register repeat return self short signed sizeof static struct subscript super switch
    template this throw throws true try typedef typename union unsigned using var virtual void
    volatile where while
    """.split()
)
JSON_EXACT = 1 << 53


class HostWireError(ValueError):
    """A schema neither codec can be built from; `str` names the JSON path."""

    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"chromium-host-wire.json: {path}: {message}")


@dataclass(frozen=True)
class Field:
    name: str
    type: str
    count: int
    role: Optional[str]
    offset: int
    doc: Tuple[str, ...]

    @property
    def size(self) -> int:
        return INT_TYPES[self.type][0]

    @property
    def signed(self) -> bool:
        return INT_TYPES[self.type][1]


@dataclass(frozen=True)
class Constant:
    name: str
    type: str
    value: int
    doc: Tuple[str, ...]


@dataclass(frozen=True)
class Kind:
    name: str
    value: int
    direction: str
    doc: Tuple[str, ...]


@dataclass(frozen=True)
class Golden:
    name: str
    doc: str
    # Field name -> value (a list for an array field), every field present.
    header: Dict[str, Any]
    payload: bytes
    hex: str


@dataclass(frozen=True)
class HostWire:
    swift_type: str
    swift_condition: Optional[str]
    cpp_namespace: str
    header_size: int
    fields: Tuple[Field, ...]
    max_payload: int
    constants: Tuple[Constant, ...]
    kinds: Tuple[Kind, ...]
    golden: Tuple[Golden, ...]

    def field(self, role: str) -> Field:
        return next(f for f in self.fields if f.role == role)


def cpp_name(name: str) -> str:
    """A constant's or kind's C++ name: wheelDeltaScale is kWheelDeltaScale."""
    return "k" + name[0].upper() + name[1:]


def type_range(type_name: str) -> Tuple[int, int]:
    size, signed = INT_TYPES[type_name]
    bits = 8 * size
    return (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)


def _require(ok: bool, path: str, message: str) -> None:
    if not ok:
        raise HostWireError(path, message)


def _object(value: Any, path: str, required: Tuple[str, ...], optional: Tuple[str, ...] = ()) -> Dict[str, Any]:
    _require(isinstance(value, dict), path, "must be an object")
    missing = [k for k in required if k not in value]
    _require(not missing, path, f"missing {', '.join(missing)}")
    unknown = sorted(set(value) - set(required) - set(optional) - {"$comment"})
    _require(not unknown, path, f"unknown key(s) {', '.join(unknown)}")
    return value


def _doc(value: Any, path: str) -> Tuple[str, ...]:
    if value is None:
        return ()
    _require(isinstance(value, list) and all(isinstance(line, str) for line in value), path, "must be a list of strings")
    _require(all("*/" not in line and "\n" not in line for line in value), path, "a line may not hold */ or a newline")
    return tuple(value)


def _integer(value: Any, path: str, type_name: str) -> int:
    """A JSON integer, or a "0x" hex string for values JSON numbers cannot hold exactly."""
    if isinstance(value, str):
        _require(re.fullmatch(r"0x[0-9a-fA-F]+", value) is not None, path, f"{value!r} is not a 0x hex string")
        number = int(value, 16)
    else:
        _require(isinstance(value, int) and not isinstance(value, bool), path, "must be an integer or a 0x string")
        _require(abs(value) < JSON_EXACT, path, "over 2^53: write it as a 0x string")
        number = value
    low, high = type_range(type_name)
    _require(low <= number <= high, path, f"{number} does not fit {type_name}")
    return number


def _name(value: Any, path: str, seen: set) -> str:
    _require(isinstance(value, str) and NAME.match(value) is not None, path, f"{value!r} is not a lowerCamelCase name")
    _require(value not in KEYWORDS, path, f"{value!r} is a Swift or C++ keyword")
    _require(value not in seen, path, f"{value!r} is named twice")
    seen.add(value)
    return value


def _fields(header: Dict[str, Any]) -> Tuple[int, Tuple[Field, ...]]:
    size = header["size"]
    _require(isinstance(size, int) and not isinstance(size, bool) and size > 0, "$.header.size", "must be a positive integer")
    entries = header["fields"]
    _require(isinstance(entries, list) and entries, "$.header.fields", "must be a non-empty list")
    fields: List[Field] = []
    offset = 0
    names: set = set()
    for index, raw in enumerate(entries):
        path = f"$.header.fields[{index}]"
        entry = _object(raw, path, ("name", "type"), ("count", "role", "doc"))
        name = _name(entry["name"], f"{path}.name", names)
        type_name = entry["type"]
        _require(type_name in INT_TYPES, f"{path}.type", f"{type_name!r} is not one of {', '.join(INT_TYPES)}")
        count = entry.get("count", 1)
        _require(isinstance(count, int) and not isinstance(count, bool) and count >= 1, f"{path}.count",
                 "must be a positive integer")
        role = entry.get("role")
        _require(role is None or role in ROLES, f"{path}.role", f"{role!r} is not one of {', '.join(ROLES)}")
        width = INT_TYPES[type_name][0]
        _require(offset % width == 0, path, f"{name} at byte {offset} is not {width}-byte aligned")
        fields.append(Field(name, type_name, count, role, offset, _doc(entry.get("doc"), f"{path}.doc")))
        offset += width * count
    _require(offset == size, "$.header", f"the fields fill {offset} bytes, not size {size}")
    for role in ROLES:
        holders = [f for f in fields if f.role == role]
        _require(len(holders) == 1, "$.header.fields", f"needs exactly one field with role {role}")
        _require(holders[0].type == "u32" and holders[0].count == 1, "$.header.fields",
                 f"the {role} field must be one u32")
    return size, tuple(fields)


def _golden(raw: Any, index: int, fields: Tuple[Field, ...], seen: set) -> Golden:
    path = f"$.golden[{index}]"
    entry = _object(raw, path, ("name", "header", "hex"), ("doc", "payload"))
    name = entry["name"]
    _require(isinstance(name, str) and GOLDEN_NAME.match(name) is not None, f"{path}.name", f"{name!r} is not a kebab-case name")
    _require(name not in seen, f"{path}.name", f"{name!r} is named twice")
    seen.add(name)
    values = _object(entry["header"], f"{path}.header", (), tuple(f.name for f in fields))
    header: Dict[str, Any] = {}
    for f in fields:
        value = values.get(f.name, [0] * f.count if f.count > 1 else 0)
        where = f"{path}.header.{f.name}"
        if f.count > 1:
            _require(isinstance(value, list) and len(value) == f.count, where, f"must be a list of {f.count}")
            header[f.name] = [_integer(v, f"{where}[{i}]", f.type) for i, v in enumerate(value)]
        else:
            header[f.name] = _integer(value, where, f.type)
    text = entry.get("payload", "")
    _require(isinstance(text, str), f"{path}.payload", "must be a string")
    payload = text.encode("utf-8")
    length = next(f for f in fields if f.role == "payload_length")
    _require(header[length.name] == len(payload), f"{path}.header.{length.name}",
             f"{header[length.name]}, but the payload is {len(payload)} bytes")
    hex_text = entry["hex"]
    _require(isinstance(hex_text, str) and re.fullmatch(r"(?:[0-9a-f]{2})*", hex_text) is not None, f"{path}.hex",
             "must be lowercase hex")
    doc = entry.get("doc", "")
    _require(isinstance(doc, str) and "\n" not in doc, f"{path}.doc", "must be one line")
    return Golden(name, doc, header, payload, hex_text)


def parse(document: Any) -> HostWire:
    """Checks a schema document and returns its model; raises HostWireError."""
    root = _object(document, "$", ("version", "byte_order", "swift", "cpp", "header", "max_payload", "constants", "kinds"),
                   ("golden",))
    _require(root["version"] == 1, "$.version", "only version 1 is known")
    _require(root["byte_order"] == "little", "$.byte_order", "only little is known")
    swift = _object(root["swift"], "$.swift", ("type",), ("condition",))
    _require(isinstance(swift["type"], str) and re.fullmatch(r"[A-Z][A-Za-z0-9]*", swift["type"]) is not None,
             "$.swift.type", "must be an UpperCamelCase type name")
    condition = swift.get("condition")
    _require(condition is None or (isinstance(condition, str) and "\n" not in condition), "$.swift.condition",
             "must be one line")
    cpp = _object(root["cpp"], "$.cpp", ("namespace",))
    _require(isinstance(cpp["namespace"], str) and re.fullmatch(r"[a-z_][a-z0-9_]*", cpp["namespace"]) is not None,
             "$.cpp.namespace", "must be a snake_case identifier")
    size, fields = _fields(_object(root["header"], "$.header", ("size", "fields")))
    max_payload = _integer(root["max_payload"], "$.max_payload", "u32")

    names: set = set()
    constants = []
    for index, raw in enumerate(root["constants"]):
        path = f"$.constants[{index}]"
        entry = _object(raw, path, ("name", "type", "value"), ("doc",))
        name = _name(entry["name"], f"{path}.name", names)
        _require(name not in ("headerSize", "maxPayload"), f"{path}.name", f"{name} is built from the header")
        _require(entry["type"] in INT_TYPES, f"{path}.type", f"{entry['type']!r} is not an integer type")
        value = _integer(entry["value"], f"{path}.value", entry["type"])
        constants.append(Constant(name, entry["type"], value, _doc(entry.get("doc"), f"{path}.doc")))

    kinds = []
    kind_names: set = set()
    values: set = set()
    for index, raw in enumerate(root["kinds"]):
        path = f"$.kinds[{index}]"
        entry = _object(raw, path, ("name", "value", "direction"), ("doc",))
        name = _name(entry["name"], f"{path}.name", kind_names)
        value = _integer(entry["value"], f"{path}.value", "u32")
        _require(value != 0, f"{path}.value", "0 is no kind")
        _require(value not in values, f"{path}.value", f"{value} is taken")
        values.add(value)
        _require(entry["direction"] in DIRECTIONS, f"{path}.direction", f"must be one of {', '.join(DIRECTIONS)}")
        kinds.append(Kind(name, value, entry["direction"], _doc(entry.get("doc"), f"{path}.doc")))
    _require(bool(kinds), "$.kinds", "must not be empty")
    clash = sorted({cpp_name(c.name) for c in constants} & {cpp_name(k.name) for k in kinds})
    _require(not clash, "$", f"a constant and a kind share the C++ name {', '.join(clash)}")

    golden_names: set = set()
    golden = tuple(_golden(raw, i, fields, golden_names) for i, raw in enumerate(root.get("golden", [])))
    wire = HostWire(swift["type"], condition, cpp["namespace"], size, fields, max_payload, tuple(constants),
                    tuple(kinds), golden)
    for index, frame in enumerate(golden):
        encoded = encode_header(wire, frame.header).hex()
        _require(encoded == frame.hex, f"$.golden[{index}].hex", f"the header fields encode as {encoded}")
    return wire


def load(path: Path) -> HostWire:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise HostWireError("$", f"cannot read {path}: {error}") from error
    return parse(document)


def encode_header(wire: HostWire, header: Dict[str, Any]) -> bytes:
    """The header bytes of `header` (field name -> value), byte order little."""
    out = bytearray()
    for f in wire.fields:
        values = header[f.name] if f.count > 1 else [header[f.name]]
        for value in values:
            out += int(value).to_bytes(f.size, "little", signed=f.signed)
    return bytes(out)
