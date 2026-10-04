"""Load and check the pane-protocol IR, and normalize its JSON Schemas."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class PaneIRError(ValueError):
    """The IR is malformed or uses a schema feature the generators do not support."""


_NS = re.compile(r"^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$")
_SEGMENT = re.compile(r"^[a-z][a-z0-9_]*$")
_KINDS = {"read", "mutation"}

# JSON Schema keywords that only annotate and never change validation.
_ANNOTATIONS = {
    "description",
    "title",
    "default",
    "examples",
    "$comment",
    "deprecated",
    "readOnly",
    "writeOnly",
    "$schema",
    "$id",
}

# Every keyword some branch of normalize() understands.
_ALL_KEYWORDS = {
    "type", "enum", "const", "format", "minimum", "maximum", "items",
    "properties", "required", "additionalProperties", "minLength", "maxLength", "pattern",
}

_REF_PREFIXES = ("#/types/", "#/$defs/", "#/definitions/")

_INT_FORMATS = {
    "int8": ("int8", -(2**7), 2**7 - 1),
    "int16": ("int16", -(2**15), 2**15 - 1),
    "int32": ("int32", -(2**31), 2**31 - 1),
    "int64": ("int64", None, None),
    "uint8": ("uint8", 0, 2**8 - 1),
    "uint16": ("uint16", 0, 2**16 - 1),
    "uint32": ("uint32", 0, 2**32 - 1),
    "uint64": ("uint64", 0, None),
    "uint": ("uint64", 0, None),
}


# Normalized schema nodes -------------------------------------------------


@dataclass(frozen=True)
class Any_:
    """Unconstrained JSON value."""


@dataclass(frozen=True)
class Null:
    pass


@dataclass(frozen=True)
class Ref:
    name: str


@dataclass(frozen=True)
class Str:
    enum: tuple[str, ...] = ()


@dataclass(frozen=True)
class Bool:
    pass


@dataclass(frozen=True)
class Num:
    pass


@dataclass(frozen=True)
class Int:
    go_type: str = "int64"
    minimum: int | None = None
    maximum: int | None = None


@dataclass(frozen=True)
class Array:
    items: Any


@dataclass(frozen=True)
class Map:
    values: Any


@dataclass(frozen=True)
class Prop:
    name: str
    node: Any
    required: bool


@dataclass(frozen=True)
class Object:
    props: tuple[Prop, ...]
    closed: bool


@dataclass(frozen=True)
class Nullable:
    inner: Any


Node = Any_ | Null | Ref | Str | Bool | Num | Int | Array | Map | Object | Nullable


def _ref_name(ref: str, where: str) -> str:
    for prefix in _REF_PREFIXES:
        if ref.startswith(prefix):
            name = ref[len(prefix) :]
            if "/" in name or not name:
                break
            return name
    raise PaneIRError(f"{where}: unsupported $ref {ref!r}")


def _reject_unknown(schema: dict[str, Any], allowed: set[str], where: str) -> None:
    extra = sorted(set(schema) - allowed - _ANNOTATIONS)
    if extra:
        raise PaneIRError(f"{where}: unsupported schema keyword(s) {extra}")


def _is_null_schema(schema: Any) -> bool:
    return isinstance(schema, dict) and schema.get("type") == "null" and set(schema) - _ANNOTATIONS == {"type"}


def normalize(schema: Any, where: str) -> Node:
    """Turn one JSON Schema into a Node, failing on anything unsupported."""

    if schema is True or schema == {}:
        return Any_()
    if not isinstance(schema, dict):
        raise PaneIRError(f"{where}: schema must be an object")
    if "$ref" in schema:
        _reject_unknown(schema, {"$ref"}, where)
        return Ref(_ref_name(schema["$ref"], where))
    for key in ("anyOf", "oneOf"):
        if key in schema:
            _reject_unknown(schema, {key}, where)
            options = schema[key]
            if (
                isinstance(options, list)
                and len(options) == 2
                and sum(_is_null_schema(o) for o in options) == 1
            ):
                other = next(o for o in options if not _is_null_schema(o))
                return Nullable(normalize(other, f"{where}.{key}"))
            raise PaneIRError(
                f"{where}: {key} is supported only as [schema, {{type: null}}]"
            )
    if set(schema) - _ANNOTATIONS == set():
        return Any_()
    if "const" in schema:
        _reject_unknown(schema, {"const", "type"}, where)
        if not isinstance(schema["const"], str):
            raise PaneIRError(f"{where}: only string const is supported")
        return Str((schema["const"],))
    _reject_unknown(schema, _ALL_KEYWORDS, where)
    if "type" not in schema:
        raise PaneIRError(f"{where}: schema has no type")
    types = schema["type"]
    if isinstance(types, str):
        types = [types]
    if not isinstance(types, list) or not types:
        raise PaneIRError(f"{where}: bad type {schema['type']!r}")
    nullable = "null" in types
    rest = [t for t in types if t != "null"]
    if len(rest) > 1:
        raise PaneIRError(f"{where}: union types {types} are not supported")
    if not rest:
        _reject_unknown(schema, {"type"}, where)
        return Null()
    node = _normalize_typed(rest[0], schema, where)
    return Nullable(node) if nullable else node


def _normalize_typed(kind: str, schema: dict[str, Any], where: str) -> Node:
    if kind == "string":
        _reject_unknown(schema, {"type", "enum", "format", "minLength", "maxLength", "pattern"}, where)
        for key in ("minLength", "maxLength", "pattern"):
            if key in schema:
                raise PaneIRError(f"{where}: {key} is not supported yet")
        enum = schema.get("enum", ())
        if any(not isinstance(e, str) for e in enum):
            raise PaneIRError(f"{where}: string enum values must be strings")
        return Str(tuple(enum))
    if kind == "boolean":
        _reject_unknown(schema, {"type"}, where)
        return Bool()
    if kind == "number":
        _reject_unknown(schema, {"type", "format"}, where)
        return Num()
    if kind == "integer":
        _reject_unknown(schema, {"type", "format", "minimum", "maximum"}, where)
        fmt = schema.get("format", "int64")
        if fmt not in _INT_FORMATS:
            raise PaneIRError(f"{where}: integer format {fmt!r} is not supported")
        go_type, lo, hi = _INT_FORMATS[fmt]
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        for label, bound in (("minimum", minimum), ("maximum", maximum)):
            if bound is not None and not (isinstance(bound, int) and not isinstance(bound, bool)):
                raise PaneIRError(f"{where}: integer {label} must be an integer")
        if lo is not None:
            minimum = lo if minimum is None else max(minimum, lo)
        if hi is not None:
            maximum = hi if maximum is None else min(maximum, hi)
        if go_type.startswith("uint") and minimum not in (None, 0):
            raise PaneIRError(f"{where}: unsigned minimum other than 0 is not supported")
        return Int(go_type, minimum, maximum)
    if kind == "array":
        _reject_unknown(schema, {"type", "items"}, where)
        if "items" not in schema:
            return Array(Any_())
        return Array(normalize(schema["items"], f"{where}.items"))
    if kind == "object":
        _reject_unknown(schema, {"type", "properties", "required", "additionalProperties"}, where)
        props = schema.get("properties", {})
        required = schema.get("required", [])
        if not isinstance(props, dict) or not isinstance(required, list):
            raise PaneIRError(f"{where}: properties must be an object and required a list")
        missing = sorted(set(required) - set(props))
        if missing:
            raise PaneIRError(f"{where}: required names unknown properties {missing}")
        additional = schema.get("additionalProperties", True)
        if not props:
            if isinstance(additional, dict):
                return Map(normalize(additional, f"{where}.additionalProperties"))
            return Map(Any_())
        if additional not in (True, False):
            raise PaneIRError(
                f"{where}: schema-valued additionalProperties next to properties is not supported"
            )
        return Object(
            tuple(
                Prop(name, normalize(props[name], f"{where}.properties.{name}"), name in required)
                for name in props
            ),
            closed=additional is False,
        )
    raise PaneIRError(f"{where}: type {kind!r} is not supported")


# The document --------------------------------------------------------------


@dataclass(frozen=True)
class Namespace:
    name: str
    owner: str

    @property
    def app(self) -> str:
        """App id that owns the namespace; first-party namespaces own themselves."""

        if self.owner.startswith("app:"):
            return self.owner[len("app:") :]
        return self.name


@dataclass(frozen=True)
class Op:
    name: str
    namespace: str
    local: tuple[str, ...]
    kind: str
    scope: str
    params: Node
    result: Node
    errors: tuple[str, ...]


@dataclass(frozen=True)
class Event:
    name: str
    namespace: str
    local: tuple[str, ...]
    scope: str
    data: Node


@dataclass(frozen=True)
class Interface:
    name: str
    ops: tuple[str, ...]
    events: tuple[str, ...]


@dataclass(frozen=True)
class PaneIR:
    version: str
    sha256: str
    namespaces: tuple[Namespace, ...]
    ops: tuple[Op, ...]
    events: tuple[Event, ...]
    interfaces: tuple[Interface, ...]
    types: dict[str, Node] = field(default_factory=dict)

    def namespace(self, name: str) -> Namespace:
        for ns in self.namespaces:
            if ns.name == name:
                return ns
        raise PaneIRError(f"unknown namespace {name!r}")


def _no_dupes(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise PaneIRError(f"duplicate JSON key {key!r}")
        out[key] = value
    return out


def _reject_constant(value: str) -> None:
    raise PaneIRError(f"non-finite number {value!r}")


def canonical_sha256(document: Any) -> str:
    text = json.dumps(document, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _split(name: str, namespaces: list[str], where: str) -> tuple[str, tuple[str, ...]]:
    owner = max((ns for ns in namespaces if name.startswith(ns + ".")), key=len, default=None)
    if owner is None:
        raise PaneIRError(f"{where}: {name!r} is outside every declared namespace")
    local = tuple(name[len(owner) + 1 :].split("."))
    if len(local) < 2 or not all(_SEGMENT.match(s) for s in local):
        raise PaneIRError(f"{where}: {name!r} must be <namespace>.<family>.<verb>")
    return owner, local


def load_pane_ir(path: str | Path) -> PaneIR:
    raw = Path(path).read_text(encoding="utf-8")
    return parse_pane_ir(raw)


def parse_pane_ir(text: str) -> PaneIR:
    try:
        document = json.loads(text, object_pairs_hook=_no_dupes, parse_constant=_reject_constant)
    except json.JSONDecodeError as error:
        raise PaneIRError(f"IR is not JSON: {error}") from error
    if not isinstance(document, dict):
        raise PaneIRError("IR must be an object")
    for key in ("version", "namespaces", "ops", "types"):
        if key not in document:
            raise PaneIRError(f"IR is missing {key!r}")

    namespaces: list[Namespace] = []
    for i, entry in enumerate(document["namespaces"]):
        name, owner = entry.get("name"), entry.get("owner")
        if not isinstance(name, str) or not _NS.match(name) or not isinstance(owner, str):
            raise PaneIRError(f"namespaces[{i}]: bad name or owner")
        if owner.startswith("app:") and owner[4:] != name:
            # The registry reserves a third party's namespace as its app id.
            raise PaneIRError(f"namespaces[{i}]: {name!r} is not its owner's app id {owner!r}")
        if owner != "first-party" and not owner.startswith("app:"):
            raise PaneIRError(f"namespaces[{i}]: owner must be first-party or app:<id>")
        if any(ns.name == name for ns in namespaces):
            raise PaneIRError(f"namespaces[{i}]: duplicate {name!r}")
        namespaces.append(Namespace(name, owner))
    ns_names = [ns.name for ns in namespaces]

    types_doc = document["types"]
    if not isinstance(types_doc, dict):
        raise PaneIRError("types must be an object")
    types = {name: normalize(schema, f"types.{name}") for name, schema in types_doc.items()}

    ops: list[Op] = []
    for i, entry in enumerate(document["ops"]):
        where = f"ops[{i}]"
        name = entry.get("name")
        if not isinstance(name, str):
            raise PaneIRError(f"{where}: missing name")
        ns, local = _split(name, ns_names, where)
        kind = entry.get("kind")
        if kind not in _KINDS:
            raise PaneIRError(f"{where}: kind must be read or mutation")
        scope = entry.get("scope")
        if not isinstance(scope, str) or not scope:
            raise PaneIRError(f"{where}: missing scope")
        errors = tuple(entry.get("errors", ()))
        for code in errors:
            if not isinstance(code, str) or not code.startswith(ns + "."):
                raise PaneIRError(f"{where}: error code {code!r} is outside namespace {ns!r}")
        if any(op.name == name for op in ops):
            raise PaneIRError(f"{where}: duplicate op {name!r}")
        ops.append(
            Op(
                name,
                ns,
                local,
                kind,
                scope,
                normalize(entry.get("params", {}), f"{where}.params"),
                normalize(entry.get("result", {}), f"{where}.result"),
                errors,
            )
        )

    events: list[Event] = []
    for i, entry in enumerate(document.get("events", ())):
        where = f"events[{i}]"
        name = entry.get("name")
        if not isinstance(name, str):
            raise PaneIRError(f"{where}: missing name")
        ns, local = _split(name, ns_names, where)
        scope = entry.get("scope")
        if not isinstance(scope, str) or not scope:
            raise PaneIRError(f"{where}: missing scope")
        if any(ev.name == name for ev in events):
            raise PaneIRError(f"{where}: duplicate event {name!r}")
        events.append(Event(name, ns, local, scope, normalize(entry.get("data", {}), f"{where}.data")))

    interfaces = tuple(
        Interface(e["name"], tuple(e.get("ops", ())), tuple(e.get("events", ())))
        for e in document.get("interfaces", ())
    )

    def check_refs(node: Node, where: str) -> None:
        if isinstance(node, Ref):
            if node.name not in types:
                raise PaneIRError(f"{where}: $ref to unknown type {node.name!r}")
        elif isinstance(node, (Array,)):
            check_refs(node.items, where)
        elif isinstance(node, Map):
            check_refs(node.values, where)
        elif isinstance(node, Nullable):
            check_refs(node.inner, where)
        elif isinstance(node, Object):
            for prop in node.props:
                check_refs(prop.node, f"{where}.{prop.name}")

    for name, node in types.items():
        check_refs(node, f"types.{name}")
    for op in ops:
        check_refs(op.params, op.name)
        check_refs(op.result, op.name)
    for ev in events:
        check_refs(ev.data, ev.name)

    return PaneIR(
        version=str(document["version"]),
        sha256=canonical_sha256(document),
        namespaces=tuple(namespaces),
        ops=tuple(ops),
        events=tuple(events),
        interfaces=interfaces,
        types=types,
    )
