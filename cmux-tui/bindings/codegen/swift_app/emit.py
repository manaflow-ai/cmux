"""Render the CmuxNextDaemon request types that bindings.json lists, from the SDK schema IR.

The schema owns the wire: command names, capabilities, field names, which fields are required, nullable or
optional, enum values and result shapes. bindings.json owns only what the schema cannot say about the Swift
side: the Swift type name, the typed id (`PaneID`, `SplitID`) an `Id` field carries, the Swift type a schema
object is bound to, the order of the init's parameters, how the app reads a result, and doc comments. A type
the bindings do not cover (an `Id` field with no Swift id type, an object or enum neither bound nor generated,
a union, a non-empty result with no response binding, a required field gated by a capability) is refused with
a BindingError, so a schema change cannot quietly produce a Swift type nobody chose. An optional field the
schema gates by a capability is generated with a doc line naming it; the caller leaves it nil for a daemon
that does not serve it, as the hand-written types did. Family keys and Swift type names must be plain Swift
identifiers: they become the output paths.

Wire rules (the same JSON the hand-written types sent):
- every field has an explicit coding key that is its wire name;
- a required field is always encoded (a nil required-nullable field encodes `null`);
- an optional field is a Swift Optional, nil by default, and encoded only when set, so an unset field
  leaves the daemon's default in force;
- `encode: if_true` on an optional boolean whose schema default is false makes a plain `Bool`, false by
  default, encoded (as `true`) only when true: a daemon without the field's capability sees the request it
  always saw;
- `encode: decimal` on an optional string the schema formats as a `decimal uint64` makes a `UInt64?`,
  sent as its decimal string when set: the caller cannot send a string that is not one;
- `with: FIELD` on an optional field sends it only when FIELD (another field of the request, an `if_true`
  flag or an Optional) is true or set: a value meaningless alone stays off the wire, as the hand-written
  types left it;
- `workspace_ref: true` folds the schema's optional `workspace` (handle) and `key` fields into one
  `workspace: WorkspaceRef` the caller must give, encoded flat as the one of the two it names
  (`WorkspaceRefFields`); `"workspace"` in `order` places it, else it comes after the fields, before
  `mutation`;
- `object: {...}` on a field whose schema type is an object makes a nested `Encodable` struct in the request
  (`name`, default the field's name as a type; `order`, `fields`, `omit`, `doc`): its fields follow these
  same rules, so it sends what the hand-written nested struct sent;
- `omit` (request or nested object) lists optional schema fields the Swift type never sends: the daemon
  keeps their default;
- `spread: {PROPERTY: TYPE}` on a request makes a property of a hand-written Swift type that encodes some
  optional schema fields flat (`TYPE.encode(to:)`, as `SpawnOptions` does): the top-level `spreads` names
  each such type's wire fields and its default, and the request sends the ones its schema has through the
  property, placed by `"PROPERTY"` in `order`;
- `constant: VALUE` on a field sends that fixed value, which the schema's type must accept: alone (or
  `encode: always`) it is always sent and makes no property; with `encode: if_true` on an optional field
  it makes a plain `Bool`, false by default, and sends the value only when true;
- `ungated: REASON` on a request whose schema gates it on a capability emits no `requiredCapability`: the app
  sends it without asking the daemon's capabilities (as the hand-written type did), and the reason is a doc
  line; a request the schema does not gate is refused;
- `init: {params, set}` on a request gives its init parameters that are not properties (`params`, each a
  `type`, optional `default` and `label`, placed by its name in `order`, else last) and sets fields from
  Swift expressions on them (`set`, wire name to expression; such a field is no init parameter): a
  `RemoteTerminalRef` or `CellSize` the caller hands over whole, encoded as the fields it fills;
- `float32` is `Double` in the app: the app keeps its precision and the daemon narrows it.

Read types (a family's `objects`): result and snapshot structs the app decodes, from a schema object
(`type`) or a command's result (`result`). A reference to a generated schema object resolves to its Swift
name. The binding may set `conformances` (default Decodable, Sendable, Equatable), `order`, `init: false`,
`omit` (schema fields the app does not read; never a required one of a type it encodes), `extra` (app-only
properties with a type and default, not on the wire) and per field the request keys plus `default` (a
Swift expression: the field decodes leniently, missing means the default), `optional: true`, `lenient: true`
(a value of the wrong shape reads as missing, so a newer daemon's value never fails the parent), `when` (a
Swift condition on properties read before it; false reads nil), `prefer` (a wire key read first, this field's
own key the fallback; the preferred key is omitted from the struct). Encoding is always synthesized; decoding is synthesized unless a
property uses one of these read options.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

try:
    from ..ir import SdkIR
except ImportError:  # Direct execution from this directory.
    from codegen.ir import SdkIR

HEADER_MARK = "// GENERATED by cmux-tui/bindings/codegen/swift_app from cmux-tui/spec/sdk-schema.json."
HEADER_EDIT = (
    "// Do not edit: change the schema or cmux-tui/bindings/codegen/swift_app/bindings.json: every build"
    " regenerates it (DaemonWireTypesPlugin)."
)

SCALARS = {
    "string": "String",
    "boolean": "Bool",
    "int32": "Int32",
    "int64": "Int64",
    "uint16": "UInt16",
    "uint32": "UInt32",
    "uint64": "UInt64",
    "float32": "Double",
    "float64": "Double",
}
PROTOCOLS = ("DaemonRequest", "TerminalSpawningRequest")
EMPTY_RESPONSE = "EmptyResponse"
JSON_VALUE = "JSONValue"
GENERATE = "generate"
HAND_WRITTEN = "hand-written"

_ACRONYMS = {"id": "ID", "ids": "IDs", "url": "URL", "urls": "URLs"}
_KEYWORDS = frozenset({
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct",
    "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "catch",
    "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try", "Any", "Type",
})
_TOP_KEYS = frozenset({"$comment", "sources_root", "ids", "types", "spreads", "families"})
_FAMILY_KEYS = frozenset({"$comment", "enums", "requests", "objects"})
_ENUM_KEYS = frozenset({"doc"})
_REQUEST_KEYS = frozenset({
    "name", "doc", "order", "fields", "response", "response_order", "response_fields", "protocol", "mutation",
    "workspace_ref", "one_of", "omit", "spread", "init", "ungated",
})
# A request init's parameters that are not properties, and the fields it sets from Swift expressions on them.
_INIT_KEYS = frozenset({"params", "set"})
_PARAM_KEYS = frozenset({"type", "default", "label"})
# A hand-written Swift type a request property encodes flat (`spreads`): the wire fields it writes, its default.
_SPREAD_KEYS = frozenset({"fields", "default", "doc"})
# A request property of a hand-written Swift enum (`one_of`): each case carries one optional schema field, and
# the request sends the field of the case it holds, so exactly one of them goes on the wire.
_ONE_OF_KEYS = frozenset({"type", "cases", "doc"})
_FIELD_KEYS = frozenset({
    "name", "type", "doc", "default", "optional", "encode", "update", "with", "object", "constant",
})
# What a `constant` field may also say: how it is sent, its Swift name and doc.
_CONSTANT_KEYS = frozenset({"constant", "encode", "name", "doc"})
_NO_CONSTANT = object()
# A request field's nested object (`object`): a struct of the request whose fields follow the request rules.
_NESTED_KEYS = frozenset({"name", "doc", "order", "fields", "omit"})
_ENCODE_MODES = {"always": True, "if_present": False}
IF_TRUE = "if_true"
DECIMAL = "decimal"
_DECIMAL_FORMAT = {"format": "decimal uint64"}
MUTATION = "mutation"
_MUTATION_WIRE = ("origin", "mutation_id", "expected_generation", "expected_revision")
WORKSPACE_REF = "workspace"
_WORKSPACE_REF_WIRE = ("workspace", "key")
# A read type's field may also take a Swift default (a lenient read: a missing key decodes as it) or be made
# optional although the schema requires it (an app that still reads an older daemon that left it out).
_READ_FIELD_KEYS = (_FIELD_KEYS - {"constant"}) | {"default", "optional", "lenient", "when", "prefer"}
_OBJECT_KEYS = frozenset({"$comment", "type", "result", "doc", "conformances", "order", "fields", "extra", "init", "omit"})
_EXTRA_KEYS = frozenset({"type", "default", "doc"})
DEFAULT_CONFORMANCES = ("Decodable", "Sendable", "Equatable")
_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class BindingError(ValueError):
    """bindings.json does not say how a schema shape becomes Swift, or names something the schema lacks."""


def _words(wire: str) -> list[str]:
    return [word for word in re.split(r"[^A-Za-z0-9]+", wire) if word]


def _escaped(name: str) -> str:
    return f"`{name}`" if name in _KEYWORDS else name


def swift_name(wire: str) -> str:
    """A wire name as a Swift property or case name: `terminal_id` -> `terminalID`, keywords in backticks."""
    words = _words(wire)
    if not words:
        raise BindingError(f"wire name {wire!r} has no letters")
    head = words[0].lower()
    tail = "".join(_ACRONYMS.get(word.lower(), word[:1].upper() + word[1:]) for word in words[1:])
    name = head + tail
    if name[0].isdigit():
        name = "v" + name
    return _escaped(name)


def type_name(wire: str) -> str:
    """A wire name as a Swift type name: `mode` -> `Mode`, `open_url` -> `OpenURL`."""
    return "".join(_ACRONYMS.get(word.lower(), word[:1].upper() + word[1:]) for word in _words(wire))


def _bare(name: str) -> str:
    return name.strip("`")


def _plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {key: _plain(value[key]) for key in value}
    if isinstance(value, tuple):
        return [_plain(item) for item in value]
    return value


def _number(value: Any) -> str:
    return json.dumps(value)


def _constraint_lines(constraints: Sequence[Any]) -> list[str]:
    lines = []
    for constraint in constraints:
        if isinstance(constraint, str):
            lines.append(constraint)
        elif {"clamped_minimum", "clamped_maximum"} <= set(constraint):
            lines.append(
                f"Clamped by the daemon to {_number(constraint['clamped_minimum'])}"
                f"...{_number(constraint['clamped_maximum'])}."
            )
        elif {"minimum", "maximum"} <= set(constraint):
            lines.append(
                f"The daemon accepts {_number(constraint['minimum'])}...{_number(constraint['maximum'])}."
            )
        else:
            lines.append(
                "Constraint: " + ", ".join(f"{key} {_number(constraint[key])}" for key in sorted(constraint)) + "."
            )
    return lines


def _doc(lines: Sequence[str], indent: str) -> list[str]:
    return [f"{indent}/// {line}".rstrip() for line in lines]


def _check_keys(where: str, value: Any, allowed: frozenset[str]) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise BindingError(f"{where} must be an object")
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise BindingError(f"{where} has unknown keys: {', '.join(unknown)}")
    return value


@dataclass
class _Enum:
    name: str
    values: list[str]
    doc: list[str] = field(default_factory=list)

    def lines(self, indent: str, *, public_doc: bool = True) -> list[str]:
        out = _doc(self.doc, indent) if public_doc else []
        out.append(f"{indent}public enum {self.name}: String, Sendable, Hashable, Codable {{")
        cases = set()
        for value in self.values:
            case = swift_name(value)
            if _bare(case) in cases:
                raise BindingError(f"enum {self.name}: two values become the Swift case {case}")
            cases.add(_bare(case))
            out.append(f"{indent}    case {case}" + ("" if _bare(case) == value else f" = {json.dumps(value)}"))
        out.append(f"{indent}}}")
        return out


@dataclass
class _Struct:
    """A request field's nested object (`object`): an Encodable struct with the request's wire rules."""

    name: str
    fields: list["_Field"]
    nested: list[Any]
    doc: list[str] = field(default_factory=list)

    def lines(self, indent: str, *, public_doc: bool = True) -> list[str]:
        inner = indent + "    "
        out = _doc(self.doc, indent) if public_doc else []
        out.append(f"{indent}public struct {self.name}: Encodable, Sendable, Equatable {{")
        for item in self.nested:
            out += [*item.lines(inner), ""]
        stored = [item for item in self.fields if item.stored]
        for item in stored:
            out += _doc(item.doc, inner)
            out.append(f"{inner}public var {item.name}: {item.declared_type}")
        out += ["", f"{inner}public init({', '.join(item.parameter() for item in stored)}) {{"]
        out += [f"{inner}    self.{item.name} = {item.name}" for item in stored]
        out.append(f"{inner}}}")
        out += ["", f"{inner}enum CodingKeys: String, CodingKey {{"]
        out += [f"{inner}    {key}" for item in self.fields for key in item.coding_keys()]
        out.append(f"{inner}}}")
        out += ["", f"{inner}public func encode(to encoder: any Encoder) throws {{"]
        out.append(f"{inner}    var container = encoder.container(keyedBy: CodingKeys.self)")
        for item in self.fields:
            out += [line.replace("        ", inner + "    ", 1) for line in item.encode_line().split("\n")]
        out.append(f"{inner}}}")
        out.append(f"{indent}}}")
        return out


@dataclass
class _Field:
    wire: str
    name: str
    swift_type: str
    optional: bool
    always_encoded: bool
    doc: list[str]
    default: str | None = None
    on_wire: bool = True
    update: bool = False
    mutation: bool = False
    # A lenient read (`lenient`): a value of the wrong shape decodes as missing instead of failing the parent.
    lenient: bool = False
    # A Swift condition on properties decoded before this one (`when`); false reads nil.
    when: str | None = None
    # A wire key read first (`prefer`), this field's own key the fallback: a newer daemon's spelling.
    prefer: str | None = None
    # Encoded only when true (`encode: if_true`): a plain Bool, false by default.
    if_true: bool = False
    # A UInt64 sent as its decimal string (`encode: decimal`).
    decimal: bool = False
    # Encoded only when this Swift condition on another field holds (`with`).
    condition: str | None = None
    # Encoded flat, not under its own key: the encoder expression's encode(to:) writes the wire fields.
    spread: str | None = None
    # A `one_of` enum: (Swift case, wire key) pairs; the value of the case it holds goes under that key.
    cases: list[tuple[str, str]] | None = None
    # An init parameter that is no property (request `init.params`), with its argument label.
    init_only: bool = False
    label: str | None = None
    # The Swift expression the init sets this field from (request `init.set`); it is no init parameter.
    assigned: str | None = None
    # A fixed value (`constant`), as a Swift literal: sent always (no property) or, with if_true, when true.
    constant: str | None = None

    @property
    def stored(self) -> bool:
        """A property of the Swift type (and a parameter of its init); an always-sent constant is neither."""
        return self.constant is None or self.if_true

    @property
    def custom_read(self) -> bool:
        return self.default is not None or self.lenient or self.when is not None or self.prefer is not None

    @property
    def declared_type(self) -> str:
        if self.update:
            return f"FieldUpdate<{self.swift_type}>"
        return self.swift_type + ("?" if self.optional else "")

    def parameter(self) -> str:
        default = self.default
        if default is None:
            default = ".unchanged" if self.update else "nil" if self.optional else None
        label = "" if self.label is None else f"{self.label} "
        return f"{label}{self.name}: {self.declared_type}" + ("" if default is None else f" = {default}")

    def encode_line(self) -> str:
        if self.spread is not None:
            return f"        try {self.spread}.encode(to: encoder)"
        if self.cases is not None:
            lines = [f"        switch {self.name} {{"]
            lines += [f"        case .{case}(let value): try container.encode(value, forKey: .{case})"
                      for case, _ in self.cases]
            return "\n".join([*lines, "        }"])
        if self.constant is not None and not self.if_true:
            return f"        try container.encode({self.constant}, forKey: .{_bare(self.name)})"
        if self.if_true:
            value = "true" if self.constant is None else self.constant
            return f"        if {self.name} {{ try container.encode({value}, forKey: .{_bare(self.name)}) }}"
        method = "encode" if self.always_encoded or self.update else "encodeIfPresent"
        line = f"try container.{method}({self.name}, forKey: .{_bare(self.name)})"
        if self.decimal:
            line = f"try container.encodeIfPresent({self.name}.map(String.init), forKey: .{_bare(self.name)})"
        if self.condition is not None:
            return f"        if {self.condition} {{ {line} }}"
        return f"        {line}"

    def coding_keys(self) -> list[str]:
        if self.cases is not None:
            return [f"case {case}" + ("" if _bare(case) == wire else f" = {json.dumps(wire)}") for case, wire in self.cases]
        return [f"case {self.name}" + ("" if _bare(self.name) == self.wire else f" = {json.dumps(self.wire)}")]


class _Renderer:
    def __init__(self, ir: SdkIR, bindings: Mapping[str, Any]):
        self.ir = ir
        bindings = _check_keys("bindings", bindings, _TOP_KEYS)
        self.ids: Mapping[str, str] = bindings.get("ids", {})
        self.bound: Mapping[str, str] = bindings.get("types", {})
        self.families: Mapping[str, Any] = bindings.get("families", {})
        self.spreads: dict[str, Mapping[str, Any]] = {}
        for name, spec in bindings.get("spreads", {}).items():
            spec = _check_keys(f"spreads.{name}", spec, _SPREAD_KEYS)
            fields = spec.get("fields")
            if (not _IDENTIFIER.fullmatch(name) or not isinstance(fields, list) or not fields
                    or len(set(fields)) != len(fields) or not isinstance(spec.get("default"), str)):
                raise BindingError(f"spreads.{name}: give the Swift type's wire fields, each once, and its default")
            self.spreads[name] = spec
        self.enums: dict[str, tuple[str, Mapping[str, Any]]] = {}
        for family, spec in sorted(self.families.items()):
            if not _IDENTIFIER.fullmatch(family):
                raise BindingError(f"family {family!r} must be one folder name of letters, digits and _")
            spec = _check_keys(f"families.{family}", spec, _FAMILY_KEYS)
            for name, enum_spec in spec.get("enums", {}).items():
                _check_keys(f"families.{family}.enums.{name}", enum_spec, _ENUM_KEYS)
                if name in self.enums or name in self.bound:
                    raise BindingError(f"enum {name} is generated twice or also bound in types")
                self.enums[name] = (family, enum_spec)
        # A schema type generated as a read type: a field that refers to it reads the generated Swift type.
        self.read_types: dict[str, str] = {}
        for family, spec in sorted(self.families.items()):
            for name, binding in spec.get("objects", {}).items():
                schema_name = binding.get("type") if isinstance(binding, Mapping) else None
                if schema_name is None:
                    continue
                if schema_name in self.read_types or schema_name in self.bound:
                    raise BindingError(f"schema type {schema_name} is generated twice or also bound in types")
                self.read_types[schema_name] = name
        for name in self.bound:
            if name not in ir.types:
                raise BindingError(f"types binds {name}, which the schema does not define")

    # Types ------------------------------------------------------------------------------------------------

    def swift_type(self, expr: Mapping[str, Any], *, where: str, wire: str, nested: list[_Enum]) -> str:
        kind = expr["kind"]
        if kind == "scalar":
            try:
                return SCALARS[expr["name"]]
            except KeyError:
                raise BindingError(f"{where}: no Swift type for scalar {expr['name']}") from None
        if kind == "opaque_json":
            return JSON_VALUE
        if kind == "array":
            return "[" + self.swift_type(expr["items"], where=where, wire=wire, nested=nested) + "]"
        if kind == "map":
            return "[String: " + self.swift_type(expr["values"], where=where, wire=wire, nested=nested) + "]"
        if kind == "enum":
            name = type_name(wire)
            if any(existing.name == name for existing in nested):
                raise BindingError(f"{where}: two inline enums become {name}")
            nested.append(_Enum(name, list(expr["values"])))
            return name
        if kind == "ref":
            return self._ref(expr["name"], where=where, wire=wire, nested=nested)
        raise BindingError(f"{where}: the Swift emitter does not support a {kind} here; bind the field's type")

    def _ref(self, name: str, *, where: str, wire: str, nested: list[_Enum]) -> str:
        if name == "Id":
            try:
                return self.ids[wire]
            except KeyError:
                raise BindingError(
                    f"{where}: an Id field needs its Swift id type; add {wire!r} to ids or give the field a type"
                ) from None
        if name in self.enums:
            return name
        if name in self.bound:
            return self.bound[name]
        if name in self.read_types:
            return self.read_types[name]
        target = self.ir.types.get(name)
        if target is None:
            raise BindingError(f"{where}: the schema has no type {name}")
        if target["kind"] == "alias":
            return self.swift_type(target["target"], where=where, wire=wire, nested=nested)
        if target["kind"] == "opaque_json":
            return JSON_VALUE
        raise BindingError(
            f"{where}: schema type {name} ({target['kind']}) is neither generated in a family's enums nor bound"
            " in types"
        )

    def fields(self, where: str, schema_fields: Mapping[str, Any], overrides: Mapping[str, Any],
               order: Sequence[str], nested: list[_Enum], *, read: bool = False) -> list[_Field]:
        for wire in overrides:
            if wire not in schema_fields:
                raise BindingError(f"{where}.{wire}: the bindings override a field the schema does not have")
        for wire in order:
            if wire not in schema_fields:
                raise BindingError(f"{where}: the order names {wire!r}, which the schema does not have")
        if len(set(order)) != len(order):
            raise BindingError(f"{where}: the order names a field twice")
        rest = sorted(
            (wire for wire in schema_fields if wire not in order),
            key=lambda wire: (schema_fields[wire]["presence"] != "required", wire),
        )
        result = []
        sent_with: dict[str, str] = {}
        for wire in [*order, *rest]:
            spec = schema_fields[wire]
            override = _check_keys(
                f"{where}.{wire}", overrides.get(wire, {}), _READ_FIELD_KEYS if read else _FIELD_KEYS
            )
            if override.get("constant", _NO_CONSTANT) is not _NO_CONSTANT:
                result.append(self.constant_field(f"{where}.{wire}", wire, spec, override))
                continue
            if "object" in override:
                if read or "type" in override or override.get("update") or "encode" in override and override[
                        "encode"] not in _ENCODE_MODES:
                    raise BindingError(f"{where}.{wire}: object is for a request field with no type, update or encode mode")
                swift_type = self.nested_object(f"{where}.{wire}", wire, spec["type"], override["object"], nested)
            else:
                swift_type = override.get("type") or self.swift_type(
                    spec["type"], where=f"{where}.{wire}", wire=wire, nested=nested
                )
            required = spec["presence"] == "required"
            if_true = decimal = False
            # A JSONValue carries null itself, so a required nullable JSON field is not an Optional.
            optional = not required or (spec["nullable"] and swift_type != JSON_VALUE)
            if read:
                default = override.get("default")
                if default is not None:
                    optional = False
                elif override.get("optional"):
                    optional = True
                always = required
                update = False
            else:
                update = override.get("update", False)
                if update is not False and (update is not True or required or not spec["nullable"]):
                    raise BindingError(f"{where}.{wire}: update is true only on an optional nullable field")
                if "optional" in override:
                    if not isinstance(override["optional"], bool) or update:
                        raise BindingError(f"{where}.{wire}: optional is true or false, and not with update")
                    optional = override["optional"]
                always = required
                if_true = override.get("encode") == IF_TRUE
                if if_true:
                    if (spec["type"] != {"kind": "scalar", "name": "boolean"} or required or update
                            or spec.get("default") is not False or "optional" in override or "type" in override
                            or override.get("default", "false") != "false"):
                        raise BindingError(
                            f"{where}.{wire}: encode if_true is for an optional boolean whose schema default is false"
                        )
                    optional, always, swift_type = False, False, "Bool"
                elif override.get("encode") == DECIMAL:
                    decimal = True
                    if (spec["type"] != {"kind": "scalar", "name": "string"} or required or update
                            or _DECIMAL_FORMAT not in spec.get("constraints", ()) or "type" in override
                            or "optional" in override or "default" in override):
                        raise BindingError(
                            f"{where}.{wire}: encode decimal is for an optional string the schema formats as a"
                            " decimal uint64"
                        )
                    swift_type = "UInt64"
                elif "encode" in override:
                    if override["encode"] not in _ENCODE_MODES or update:
                        raise BindingError(f"{where}.{wire}: encode is always or if_present, and not with update")
                    always = _ENCODE_MODES[override["encode"]]
                if not optional and not always and not if_true:
                    raise BindingError(f"{where}.{wire}: a field that is not Optional is always encoded")
                default = override.get("default")
                if default is not None and (not isinstance(default, str) or not default):
                    raise BindingError(f"{where}.{wire}: default is a Swift expression")
                if if_true:
                    default = "false"
                if "with" in override:
                    other = override["with"]
                    if (not isinstance(other, str) or other == wire or other not in schema_fields
                            or not optional or update or always):
                        raise BindingError(
                            f"{where}.{wire}: with names another field of the request, on an optional field"
                            " sent only when set"
                        )
                    sent_with[wire] = other
            if read and "with" in override:
                raise BindingError(f"{where}.{wire}: with is for a request field")
            doc = list(override.get("doc") or ([spec["description"]] if spec.get("description") else []))
            doc += _constraint_lines(spec.get("constraints", ()))
            if spec.get("capability") and read:
                doc.append(f"Sent with `{spec['capability']}`" + ("; nil from a daemon without it." if optional else "."))
            elif spec.get("capability"):
                if required:
                    raise BindingError(
                        f"{where}.{wire}: a required field gated by {spec['capability']} has no Swift shape"
                    )
                since = f" (protocol {spec['since']})" if spec.get("since") is not None else ""
                unset = "false" if if_true else "nil"
                doc.append(
                    f"Needs `{spec['capability']}`{since}; leave it {unset} for a daemon that does not serve it."
                )
            result.append(_Field(
                wire=wire,
                name=_escaped(override["name"]) if "name" in override else swift_name(wire),
                swift_type=swift_type,
                optional=optional,
                always_encoded=always,
                doc=doc,
                default=default,
                lenient=bool(override.get("lenient")),
                when=override.get("when"),
                prefer=override.get("prefer"),
                update=update,
                if_true=if_true,
                decimal=decimal,
            ))
            made = result[-1]
            if made.lenient and not made.optional and made.default is None:
                raise BindingError(f"{where}.{wire}: lenient needs an optional field or a default")
            if made.when is not None and not made.optional:
                raise BindingError(f"{where}.{wire}: when needs an optional field (a false condition reads nil)")
        names = [_bare(item.name) for item in result]
        if len(set(names)) != len(names):
            raise BindingError(f"{where}: two fields become the same Swift name")
        by_wire = {item.wire: item for item in result}
        for wire, other in sent_with.items():
            target, gate = by_wire[wire], by_wire[other]
            if gate.if_true:
                target.condition = gate.name
            elif gate.optional and not gate.update and gate.condition is None:
                target.condition = f"{gate.name} != nil"
            else:
                raise BindingError(
                    f"{where}.{wire}: with names {other!r}, which is neither an if_true flag nor an Optional"
                )
            target.doc.append(f"Sent only with `{_bare(gate.name)}`.")
        return result

    def constant_field(self, where: str, wire: str, spec: Mapping[str, Any], override: Mapping[str, Any]) -> _Field:
        """The field a `constant` binding makes: a fixed value, always sent or sent when its Bool is true."""
        if set(override) - _CONSTANT_KEYS or override.get("encode", "always") not in ("always", IF_TRUE):
            raise BindingError(f"{where}: a constant takes only encode (always or if_true), name and doc")
        value = override["constant"]
        if not self.accepts(spec["type"], value):
            raise BindingError(f"{where}: constant {value!r} is not a value of the schema's type")
        if_true = override.get("encode") == IF_TRUE
        if if_true and spec["presence"] == "required":
            raise BindingError(f"{where}: encode if_true sends the constant only when true; the schema requires it")
        literal = json.dumps(value)
        doc = list(override.get("doc") or ([spec["description"]] if spec.get("description") else []))
        if if_true:
            doc.append(f"Sends `{wire}: {literal}` when true.")
            if spec.get("capability"):
                since = f" (protocol {spec['since']})" if spec.get("since") is not None else ""
                doc.append(f"Needs `{spec['capability']}`{since}; leave it false for a daemon that does not serve it.")
        return _Field(
            wire=wire, name=_escaped(override["name"]) if "name" in override else swift_name(wire), swift_type="Bool",
            optional=False, always_encoded=not if_true, doc=doc, default="false" if if_true else None,
            if_true=if_true, constant=literal,
        )

    def accepts(self, expr: Mapping[str, Any], value: Any) -> bool:
        """Whether the schema type takes this JSON value (a `constant`)."""
        kind = expr["kind"]
        if kind == "ref":
            target = self.ir.types.get(expr["name"])
            return target is not None and self.accepts(target.get("target", target), value)
        if kind == "enum":
            return isinstance(value, str) and value in expr["values"]
        if kind != "scalar":
            return False
        name = expr["name"]
        if name == "string":
            return isinstance(value, str)
        if name == "boolean":
            return isinstance(value, bool)
        if name.startswith(("int", "uint")):
            return isinstance(value, int) and not isinstance(value, bool) and (value >= 0 or name.startswith("int"))
        return isinstance(value, (int, float)) and not isinstance(value, bool)

    def nested_object(self, where: str, wire: str, expr: Mapping[str, Any], binding: Any,
                      nested: list[Any]) -> str:
        """The nested struct an `object` field binding makes; its Swift name."""
        binding = _check_keys(f"{where}.object", binding, _NESTED_KEYS)
        if expr["kind"] == "ref" and expr["name"] in {**self.bound, **self.read_types, **self.enums}:
            raise BindingError(f"{where}: schema type {expr['name']} already has a Swift type; drop the object binding")
        target = self._object(expr)
        if target is None:
            raise BindingError(f"{where}: object is for a field whose schema type is an object")
        name = binding.get("name") or type_name(wire)
        if not isinstance(name, str) or not _IDENTIFIER.fullmatch(name) or name in _KEYWORDS:
            raise BindingError(f"{where}.object: {name!r} is not a Swift type name")
        if any(existing.name == name for existing in nested):
            raise BindingError(f"{where}: two nested types become {name}")
        schema_fields = self.omitting(f"{where}.object", target["fields"], binding)
        if not schema_fields:
            raise BindingError(f"{where}.object: the nested object sends no field")
        inner: list[Any] = []
        fields = self.fields(f"{where}.object", schema_fields, binding.get("fields", {}),
                             list(binding.get("order", ())), inner)
        for item in fields:
            if item.update:
                raise BindingError(f"{where}.object.{item.wire}: update is for a request's own field")
        nested.append(_Struct(name, fields, inner, list(binding.get("doc", ()))))
        return name

    @staticmethod
    def omitting(where: str, schema_fields: Mapping[str, Any], binding: Mapping[str, Any]) -> dict[str, Any]:
        """The schema fields less the binding's `omit`: optional fields the Swift type never sends."""
        omit = binding.get("omit", [])
        if not isinstance(omit, list) or len(set(omit)) != len(omit):
            raise BindingError(f"{where}: omit lists schema fields, each once")
        for wire in omit:
            spec = schema_fields.get(wire)
            if spec is None or spec["presence"] == "required":
                raise BindingError(f"{where}: omit names {wire!r}, which is not an optional field of the schema")
            if wire in binding.get("fields", {}) or wire in binding.get("order", ()):
                raise BindingError(f"{where}: omit names {wire!r}, which the binding also binds")
        return {wire: spec for wire, spec in schema_fields.items() if wire not in omit}

    # Files ------------------------------------------------------------------------------------------------

    def render(self) -> dict[str, str]:
        files: dict[str, str] = {}
        seen: set[str] = set()

        def add(family: str, name: str, lines: list[str]) -> None:
            if not _IDENTIFIER.fullmatch(name) or name in _KEYWORDS:
                raise BindingError(f"{family}: {name!r} is not a Swift type name")
            if name in seen:
                raise BindingError(f"two bindings generate the Swift type {name}")
            seen.add(name)
            files[f"{family}/{name}.generated.swift"] = "\n".join(
                [HEADER_MARK, HEADER_EDIT, "", "import Foundation", "", *lines]
            ) + "\n"

        for name, (family, spec) in sorted(self.enums.items()):
            schema_type = self.ir.types.get(name)
            if schema_type is None or schema_type["kind"] != "enum":
                raise BindingError(f"families.{family}.enums.{name}: the schema has no enum {name}")
            add(family, name, _Enum(name, list(schema_type["values"]), list(spec.get("doc", ()))).lines(""))
        for family, spec in sorted(self.families.items()):
            for command, request in sorted(spec.get("requests", {}).items()):
                request = _check_keys(f"{family}.{command}", request, _REQUEST_KEYS)
                if "name" not in request:
                    raise BindingError(f"{command}: the binding needs the Swift type name")
                add(family, request["name"], self.request(command, request))
            for name, binding in sorted(spec.get("objects", {}).items()):
                binding = _check_keys(f"{family}.objects.{name}", binding, _OBJECT_KEYS)
                add(family, name, self.read_type(f"{family}.objects.{name}", name, binding))
        return dict(sorted(files.items()))

    def request(self, command: str, binding: Mapping[str, Any]) -> list[str]:
        try:
            schema = self.ir.command(command)
        except KeyError:
            raise BindingError(f"{command}: bindings name a command the schema does not have") from None
        request = schema["request"]
        if request["kind"] != "object":
            raise BindingError(f"{command}: the request is a {request['kind']}, not an object")
        protocol = binding.get("protocol", PROTOCOLS[0])
        if protocol not in PROTOCOLS:
            raise BindingError(f"{command}: protocol must be one of {', '.join(PROTOCOLS)}")
        nested: list[Any] = []
        schema_fields = self.omitting(command, request["fields"], binding)
        order = list(binding.get("order", ()))
        mutation = binding.get("mutation", False)
        if mutation not in (True, False):
            raise BindingError(f"{command}: mutation is true or false")
        if mutation:
            if not {"origin", "mutation_id"} <= set(schema_fields):
                raise BindingError(f"{command}: mutation needs the schema's origin and mutation_id fields")
            schema_fields = {wire: spec for wire, spec in schema_fields.items() if wire not in _MUTATION_WIRE}
        workspace_ref = binding.get("workspace_ref", False)
        if workspace_ref not in (True, False):
            raise BindingError(f"{command}: workspace_ref is true or false")
        if workspace_ref:
            for wire in _WORKSPACE_REF_WIRE:
                spec = schema_fields.get(wire)
                if spec is None or spec["presence"] == "required":
                    raise BindingError(f"{command}: workspace_ref needs the schema's optional workspace and key fields")
            if any(wire in binding.get("fields", {}) for wire in _WORKSPACE_REF_WIRE):
                raise BindingError(f"{command}: workspace_ref owns the workspace and key fields; bind neither")
            schema_fields = {wire: spec for wire, spec in schema_fields.items() if wire not in _WORKSPACE_REF_WIRE}
        spread = binding.get("spread", {})
        if not isinstance(spread, Mapping):
            raise BindingError(f"{command}: spread maps a Swift property to a type of the top-level spreads")
        spread_wire: dict[str, list[str]] = {}
        for token, swift in spread.items():
            if not _IDENTIFIER.fullmatch(token) or swift not in self.spreads:
                raise BindingError(f"{command}.spread.{token}: name a Swift type of the top-level spreads")
            covered = [wire for wire in self.spreads[swift]["fields"] if wire in schema_fields]
            if not covered:
                raise BindingError(f"{command}.spread.{token}: {swift} sends none of this command's fields")
            for wire in covered:
                if any(wire in sent for sent in spread_wire.values()):
                    raise BindingError(f"{command}.spread.{token}: two spreads send {wire}")
                if schema_fields[wire]["presence"] == "required":
                    raise BindingError(f"{command}.spread.{token}: {wire} is required; a spread sends optional fields")
                if wire in binding.get("fields", {}) or wire in order:
                    raise BindingError(f"{command}.spread.{token}: {swift} sends {wire}; bind it in neither fields nor order")
            spread_wire[token] = covered
        schema_fields = {
            wire: spec for wire, spec in schema_fields.items() if not any(wire in sent for sent in spread_wire.values())
        }
        # Spread fields leave the schema's fields and come back at their place in `order` (else last).
        spreads: list[tuple[str, _Field]] = []
        if workspace_ref:
            spreads.append((WORKSPACE_REF, _Field(
                wire=WORKSPACE_REF, name=WORKSPACE_REF, swift_type="WorkspaceRef", optional=False,
                always_encoded=True, doc=[], spread=f"WorkspaceRefFields(ref: {WORKSPACE_REF})",
            )))
        if mutation:
            spreads.append((MUTATION, _Field(
                wire=MUTATION, name=MUTATION, swift_type="MutationIdentity", optional=True, always_encoded=False,
                doc=["The exactly-once key (`origin`, `mutation_id`); reuse it on every retry of this write."],
                mutation=True, spread=f"MutationFields(identity: {MUTATION})",
            )))
        for token, swift in spread.items():
            sent = ", ".join(f"`{wire}`" for wire in spread_wire[token])
            spreads.append((token, _Field(
                wire=token, name=token, swift_type=swift, optional=False, always_encoded=True,
                doc=[*self.spreads[swift].get("doc", ()), f"Carries this command's {sent}, encoded flat, each when set."],
                default=self.spreads[swift]["default"], spread=token,
            )))
        one_of = binding.get("one_of", {})
        if not isinstance(one_of, Mapping):
            raise BindingError(f"{command}: one_of maps a Swift property to its enum")
        taken: set[str] = set()
        for token, spec in one_of.items():
            spec = _check_keys(f"{command}.one_of.{token}", spec, _ONE_OF_KEYS)
            cases = spec.get("cases")
            if (not _IDENTIFIER.fullmatch(token) or not isinstance(spec.get("type"), str)
                    or not isinstance(cases, list) or len(cases) < 2 or not taken.isdisjoint(cases)
                    or len(set(cases)) != len(cases)):
                raise BindingError(
                    f"{command}.one_of.{token}: give a Swift enum type and two or more schema fields as its cases,"
                    " each in one one_of"
                )
            taken.update(cases)
            if any(wire in order for wire in cases):
                raise BindingError(f"{command}.one_of.{token}: order names the property {token}, not its cases")
        init = _check_keys(f"{command}.init", binding.get("init", {}), _INIT_KEYS)
        params, assigned = init.get("params", {}), init.get("set", {})
        if not isinstance(params, Mapping) or not isinstance(assigned, Mapping) or (init and not assigned):
            raise BindingError(f"{command}.init: params maps a name to its type, set a field to a Swift expression")
        for token, spec in params.items():
            spec = _check_keys(f"{command}.init.params.{token}", spec, _PARAM_KEYS)
            label = spec.get("label")
            if (not _IDENTIFIER.fullmatch(token) or token in _KEYWORDS or not isinstance(spec.get("type"), str)
                    or not spec["type"] or not isinstance(spec.get("default", ""), str)
                    or label is not None and (not isinstance(label, str) or not _IDENTIFIER.fullmatch(label))):
                raise BindingError(
                    f"{command}.init.params.{token}: a parameter is a Swift name with a type, an optional"
                    " default and an optional label (`_`)"
                )
            if not any(re.search(rf"\b{token}\b", str(expression)) for expression in assigned.values()):
                raise BindingError(f"{command}.init.params.{token}: no set expression reads it")
            spreads.append((token, _Field(
                wire=token, name=token, swift_type=spec["type"], optional=False, always_encoded=False, doc=[],
                default=spec.get("default"), on_wire=False, init_only=True, label=label,
            )))
        for wire, expression in assigned.items():
            if not isinstance(expression, str) or not expression:
                raise BindingError(f"{command}.init.set.{wire}: set gives a Swift expression")
            if wire in order:
                raise BindingError(f"{command}.init.set.{wire}: the init sets it, so it is no parameter; drop it from order")
        places = {
            token: order.index(token) for token in [*(token for token, _ in spreads), *one_of] if token in order
        }
        order = [item for item in order if item not in places]
        fields = self.fields(command, schema_fields, binding.get("fields", {}), order, nested)
        for token, spec in one_of.items():
            by_wire = {item.wire: item for item in fields}
            cases = []
            for wire in spec["cases"]:
                case = by_wire.get(wire)
                if (case is None or not case.optional or case.always_encoded or case.update or case.if_true
                        or case.decimal or case.condition is not None or case.default is not None):
                    raise BindingError(
                        f"{command}.one_of.{token}: case {wire} is an optional schema field sent only when set"
                    )
                cases.append((case.name, wire))
            fields = [item for item in fields if item.wire not in spec["cases"]]
            spreads.append((token, _Field(
                wire=token, name=token, swift_type=spec["type"], optional=False, always_encoded=True,
                doc=list(spec.get("doc", ())), cases=cases,
            )))
        for token, spread in spreads:
            if token in (_bare(item.name) for item in fields):
                raise BindingError(f"{command}: a field is already named {token}")
        for token, spread in sorted(spreads, key=lambda pair: places.get(pair[0], len(order) + len(spreads))):
            fields.insert(min(places.get(token, len(fields)), len(fields)), spread)
        by_wire = {item.wire: item for item in fields if not item.init_only}
        for wire, expression in assigned.items():
            item = by_wire.get(wire)
            if (item is None or item.spread is not None or item.cases is not None or item.constant is not None
                    or wire not in request["fields"]):
                raise BindingError(f"{command}.init.set.{wire}: set names a field of the request's schema")
            item.assigned = expression
        properties = [item for item in fields if not item.init_only]
        stored = [item for item in properties if item.stored]
        keyed = [item for item in properties if item.spread is None]
        if len({key for item in keyed for key in item.coding_keys()}) != sum(len(item.coding_keys()) for item in keyed):
            raise BindingError(f"{command}: two fields encode under the same key")
        response = self.response_binding(command, schema["result"], binding)
        ungated = binding.get("ungated")
        if ungated is not None and (not isinstance(ungated, str) or not ungated.strip()):
            raise BindingError(f"{command}: ungated gives the reason the app sends it without asking")
        if ungated is not None and not schema.get("capability"):
            raise BindingError(f"{command}: ungated, but the schema gates it on no capability")
        capability = None if ungated is not None else schema.get("capability")

        name = binding["name"]
        doc = list(binding.get("doc") or [f"`{command}`."])
        if ungated is not None:
            doc += ["", f"The schema gates it on `{schema['capability']}`; the app sends it without asking:", ungated.strip()]
        out = _doc(doc, "")
        out.append(f"public struct {name}: {protocol} {{")
        if response not in (GENERATE, HAND_WRITTEN):
            out.append(f"    public typealias Response = {response}")
        out.append(f"    public static let command = {json.dumps(command)}")
        if capability:
            out.append(f"    public static let requiredCapability: String? = {json.dumps(capability)}")
        for enum in nested:
            out += ["", *enum.lines("    ")]
        if stored:
            out.append("")
        for item in stored:
            out += _doc(item.doc, "    ")
            out.append(f"    public var {item.name}: {item.declared_type}")
        out += ["", f"    public init({', '.join(item.parameter() for item in fields if item.assigned is None and item.stored)}) {{"]
        out += [f"        self.{item.name} = {item.name if item.assigned is None else item.assigned}" for item in stored]
        out.append("    }")
        if keyed:
            out += ["", "    enum CodingKeys: String, CodingKey {"]
            out += [f"        {key}" for item in keyed for key in item.coding_keys()]
            out.append("    }")
        if properties:
            out += ["", "    public func encode(to encoder: any Encoder) throws {"]
            if keyed:
                out.append("        var container = encoder.container(keyedBy: CodingKeys.self)")
            out += [item.encode_line() for item in [*keyed, *(item for item in properties if item.spread is not None)]]
            out.append("    }")
        if response == GENERATE:
            out += ["", *self.response(command, schema["result"], binding)]
        out.append("}")
        return out

    def response_binding(self, command: str, result: Mapping[str, Any], binding: Mapping[str, Any]) -> str:
        if "response" in binding:
            return binding["response"]
        if self._is_empty_object(result):
            return EMPTY_RESPONSE
        raise BindingError(
            f"{command}: the result is not empty, so the binding must say how Swift reads it:"
            f" {GENERATE!r}, {HAND_WRITTEN!r} or a Swift type name"
        )

    def _object(self, expr: Mapping[str, Any]) -> Mapping[str, Any] | None:
        if expr["kind"] == "ref":
            expr = self.ir.types.get(expr["name"], {"kind": "missing"})
        return expr if expr["kind"] == "object" else None

    def _is_empty_object(self, expr: Mapping[str, Any]) -> bool:
        target = self._object(expr)
        return target is not None and not target["fields"]

    def response(self, command: str, result: Mapping[str, Any], binding: Mapping[str, Any]) -> list[str]:
        target = self._object(result)
        if target is None:
            raise BindingError(f"{command}: only an object result can be generated")
        nested: list[_Enum] = []
        fields = self.fields(
            f"{command}.result", target["fields"], binding.get("response_fields", {}),
            binding.get("response_order", ()), nested,
        )
        out = ["    public struct Response: Decodable, Sendable, Equatable {"]
        for enum in nested:
            out += [*enum.lines("        "), ""]
        for item in fields:
            out += _doc(item.doc, "        ")
            out.append(f"        public var {item.name}: {item.declared_type}")
        out += ["", f"        public init({', '.join(item.parameter() for item in fields)}) {{"]
        out += [f"            self.{item.name} = {item.name}" for item in fields]
        out.append("        }")
        if fields:
            out += ["", "        enum CodingKeys: String, CodingKey {"]
            out += [f"            {key}" for item in fields for key in item.coding_keys()]
            out.append("        }")
        out.append("    }")
        return out


    def read_type(self, where: str, name: str, binding: Mapping[str, Any]) -> list[str]:
        """A schema object (a type, or a command's result) as a standalone Swift struct the app reads."""
        if ("type" in binding) == ("result" in binding):
            raise BindingError(f"{where}: name exactly one of type (a schema type) or result (a command)")
        if "type" in binding:
            target = self.ir.types.get(binding["type"])
            source = binding["type"]
            if target is None or target["kind"] != "object":
                raise BindingError(f"{where}: the schema has no object type {binding['type']}")
        else:
            try:
                schema = self.ir.command(binding["result"])
            except KeyError:
                raise BindingError(f"{where}: the schema has no command {binding['result']}") from None
            target = self._object(schema["result"])
            source = f"{binding['result']}.result"
            if target is None:
                raise BindingError(f"{where}: {binding['result']}'s result is not an object")
        omit = list(binding.get("omit", ()))
        for wire in omit:
            if wire not in target["fields"]:
                raise BindingError(f"{where}: omit names {wire!r}, which the schema does not have")
            encodes = {"Encodable", "Codable"} & set(binding.get("conformances", DEFAULT_CONFORMANCES))
            if encodes and target["fields"][wire]["presence"] == "required":
                raise BindingError(f"{where}: omit names {wire!r}, which the schema requires and this type sends")
        schema_fields = {wire: spec for wire, spec in target["fields"].items() if wire not in omit}
        extra = binding.get("extra", {})
        order = list(binding.get("order", ()))
        wire_order = [item for item in order if item not in extra]
        nested: list[_Enum] = []
        fields = self.fields(source, schema_fields, binding.get("fields", {}), wire_order, nested, read=True)
        by_key: dict[str, _Field] = {item.wire: item for item in fields}
        for key, spec in extra.items():
            spec = _check_keys(f"{where}.extra.{key}", spec, _EXTRA_KEYS)
            if key in schema_fields:
                raise BindingError(f"{where}.extra.{key}: the schema has this field; bind it in fields")
            if "type" not in spec or "default" not in spec:
                raise BindingError(f"{where}.extra.{key}: an app-only property needs its type and default")
            by_key[key] = _Field(
                wire=key, name=_escaped(key), swift_type=spec["type"], optional=False, always_encoded=False,
                doc=list(spec.get("doc", ())), default=spec["default"], on_wire=False,
            )
        ordered = [by_key[key] for key in order] + [item for key, item in by_key.items() if key not in order]
        names = [_bare(item.name) for item in ordered]
        if len(set(names)) != len(names):
            raise BindingError(f"{where}: two properties become the same Swift name")
        wire = [item for item in ordered if item.on_wire]
        preferred: list[tuple[str, str]] = []
        for item in wire:
            if item.prefer is None:
                continue
            if item.prefer not in target["fields"]:
                raise BindingError(f"{where}.{item.wire}: prefer names {item.prefer!r}, which the schema does not have")
            if item.prefer in schema_fields:
                raise BindingError(f"{where}.{item.wire}: prefer reads {item.prefer!r} into this field; omit it")
            preferred.append((swift_name(item.prefer), item.prefer))
        conformances = binding.get("conformances", list(DEFAULT_CONFORMANCES))
        decodes = "Decodable" in conformances or "Codable" in conformances

        out = _doc(binding.get("doc") or [f"`{source}`."], "")
        out.append(f"public struct {name}: {', '.join(conformances)} {{")
        for enum in nested:
            out += [*enum.lines("    "), ""]
        for item in ordered:
            out += _doc(item.doc, "    ")
            out.append(f"    public var {item.name}: {item.declared_type}")
        if binding.get("init", True):
            out += ["", f"    public init({', '.join(item.parameter() for item in ordered)}) {{"]
            out += [f"        self.{item.name} = {item.name}" for item in ordered]
            out.append("    }")
        if wire:
            out += ["", "    enum CodingKeys: String, CodingKey {"]
            out += [f"        {key}" for item in wire for key in item.coding_keys()]
            out += [f"        case {key} = {json.dumps(value)}" for key, value in preferred]
            out.append("    }")
        if decodes and any(item.custom_read for item in ordered):
            # A lenient read: a key the daemon left out decodes as the property's default.
            out += ["", "    public init(from decoder: any Decoder) throws {"]
            out.append("        let container = try decoder.container(keyedBy: CodingKeys.self)")
            for item in ordered:
                out.append(f"        {item.name} = {_read_expression(item)}")
            out.append("    }")
        out.append("}")
        return out


def _read_expression(item: _Field) -> str:
    """The Swift expression `init(from:)` assigns to one read-type property."""
    if not item.on_wire:
        return str(item.default)
    key = f".{_bare(item.name)}"
    if not item.optional and item.default is None and item.prefer is None:
        return f"try container.decode({item.swift_type}.self, forKey: {key})"
    keys = ([f".{_bare(swift_name(item.prefer))}"] if item.prefer is not None else []) + [key]
    reads = [f"container.decodeIfPresent({item.swift_type}.self, forKey: {each})" for each in keys]
    if item.lenient:
        expression = " ?? ".join(f"((try? {read}) ?? nil)" for read in reads)
    else:
        expression = "try " + " ?? ".join(reads)
    if item.default is not None:
        expression = f"({expression}) ?? {item.default}" if item.lenient else f"{expression} ?? {item.default}"
    if item.when is not None:
        expression = f"{item.when} ? ({expression}) : nil"
    return expression


def render(ir: SdkIR, bindings: Mapping[str, Any]) -> dict[str, str]:
    """Every generated file, keyed by its path under the bindings' output_root."""
    return _Renderer(ir, _plain(bindings)).render()
