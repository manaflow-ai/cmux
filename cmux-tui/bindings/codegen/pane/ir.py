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


# Namespace and app id labels are [a-z0-9_], dot-separated, the first label
# starting with a letter (Rust lane R11).
_NS = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)*$")
_SEGMENT = re.compile(r"^[a-z][a-z0-9_-]*$")
_KINDS = {"read", "mutation", "stream"}

# JSON Schema keywords that only annotate and never change validation. Same
# list as the Rust lane's decision-9 subset (vectors.json ir_keywords).
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

# Every validating keyword normalize() understands: the decision-9 subset.
SUPPORTED_KEYWORDS = {
    "type", "$ref", "properties", "required", "additionalProperties", "items",
    "enum", "const", "anyOf", "oneOf", "allOf", "minimum", "maximum",
    "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "pattern",
    "minItems", "maxItems", "format", "x-cmux-secret",
}

_REF_PREFIXES = ("#/types/", "#/$defs/", "#/definitions/")

# Regex features outside the RE2/ECMA-262 common subset (decision 19):
# lookaround, backreferences and named groups. A pattern that uses them is
# refused rather than validated differently in different languages.
_NON_RE2 = re.compile(r"\(\?(?:=|!|<=|<!|<[A-Za-z]|P<|')|\\[1-9]|\\k<")

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
    min_length: int | None = None
    max_length: int | None = None
    pattern: str | None = None


@dataclass(frozen=True)
class Bool:
    pass


@dataclass(frozen=True)
class Num:
    minimum: float | None = None
    maximum: float | None = None
    exclusive_minimum: float | None = None
    exclusive_maximum: float | None = None


@dataclass(frozen=True)
class Int:
    go_type: str = "int64"
    minimum: int | None = None
    maximum: int | None = None


@dataclass(frozen=True)
class Array:
    items: Any
    min_items: int | None = None
    max_items: int | None = None


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
class Union:
    """oneOf of objects told apart by a required string const property."""

    tag: str
    variants: tuple[tuple[str, Object], ...]


@dataclass(frozen=True)
class Nullable:
    inner: Any


Node = Any_ | Null | Ref | Str | Bool | Num | Int | Array | Map | Object | Union | Nullable


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


def _int(schema: dict[str, Any], key: str, where: str) -> int | None:
    value = schema.get(key)
    if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
        raise PaneIRError(f"{where}: {key} must be a non-negative integer")
    return value


def _number(schema: dict[str, Any], key: str, where: str) -> float | int | None:
    value = schema.get(key)
    if value is not None and (not isinstance(value, (int, float)) or isinstance(value, bool)):
        raise PaneIRError(f"{where}: {key} must be a number")
    return value


def _string_const(schema: Any) -> str | None:
    if isinstance(schema, dict) and isinstance(schema.get("const"), str):
        if set(schema) - _ANNOTATIONS <= {"const", "type"} and schema.get("type", "string") == "string":
            return schema["const"]
    return None


def _union(options: list[Any], where: str) -> Node:
    """oneOf of string consts (an enum) or of tagged objects."""

    consts = [_string_const(o) for o in options]
    if all(c is not None for c in consts):
        if len(set(consts)) != len(consts):
            raise PaneIRError(f"{where}: duplicate const in oneOf")
        return Str(tuple(consts))
    variants = [normalize(o, f"{where}.oneOf[{i}]") for i, o in enumerate(options)]
    if not all(isinstance(v, Object) for v in variants):
        raise PaneIRError(
            f"{where}: oneOf is supported only as [schema, {{type: null}}], string consts, "
            "or objects tagged by a required string const property"
        )
    for prop in variants[0].props:
        tags = []
        for variant in variants:
            match = next((p for p in variant.props if p.name == prop.name), None)
            if match is None or not match.required or not isinstance(match.node, Str) or len(match.node.enum) != 1:
                break
            tags.append(match.node.enum[0])
        else:
            if len(set(tags)) == len(tags):
                return Union(prop.name, tuple(zip(tags, variants)))
    raise PaneIRError(f"{where}: oneOf objects need a common required string const tag property")


def normalize(schema: Any, where: str) -> Node:
    """Turn one JSON Schema into a Node, failing on anything unsupported."""

    if schema is True or schema == {}:
        return Any_()
    if not isinstance(schema, dict):
        raise PaneIRError(f"{where}: schema must be an object")
    if "x-cmux-secret" in schema:
        # Decision 21: marks a secret property; it does not change validation.
        if not isinstance(schema["x-cmux-secret"], bool):
            raise PaneIRError(f"{where}: x-cmux-secret must be a boolean")
        schema = {k: v for k, v in schema.items() if k != "x-cmux-secret"}
        if not schema:
            return Any_()
    _reject_unknown(schema, SUPPORTED_KEYWORDS, where)
    if "$ref" in schema:
        _reject_unknown(schema, {"$ref"}, where)
        return Ref(_ref_name(schema["$ref"], where))
    if "allOf" in schema:
        _reject_unknown(schema, {"allOf"}, where)
        options = schema["allOf"]
        if isinstance(options, list) and len(options) == 1:
            return normalize(options[0], f"{where}.allOf[0]")
        raise PaneIRError(f"{where}: allOf is supported only with one schema")
    for key in ("anyOf", "oneOf"):
        if key in schema:
            _reject_unknown(schema, {key}, where)
            options = schema[key]
            if not isinstance(options, list) or len(options) < 2:
                raise PaneIRError(f"{where}: {key} needs at least two schemas")
            nulls = [o for o in options if _is_null_schema(o)]
            others = [o for o in options if not _is_null_schema(o)]
            if len(nulls) == 1 and len(others) == 1:
                return Nullable(normalize(others[0], f"{where}.{key}"))
            if key == "oneOf" and not nulls:
                return _union(options, where)
            raise PaneIRError(
                f"{where}: {key} is supported only as [schema, {{type: null}}]"
                + (", string consts, or tagged objects" if key == "oneOf" else "")
            )
    if set(schema) - _ANNOTATIONS == set():
        return Any_()
    if "const" in schema:
        _reject_unknown(schema, {"const", "type"}, where)
        if not isinstance(schema["const"], str) or schema.get("type", "string") != "string":
            raise PaneIRError(f"{where}: only string const is supported")
        return Str((schema["const"],))
    if "type" not in schema:
        if "enum" in schema and set(schema) - _ANNOTATIONS == {"enum"}:
            return _normalize_typed("string", schema, where)
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
        enum = schema.get("enum", ())
        if any(not isinstance(e, str) for e in enum):
            raise PaneIRError(f"{where}: string enum values must be strings")
        pattern = schema.get("pattern")
        if pattern is not None:
            if not isinstance(pattern, str):
                raise PaneIRError(f"{where}: pattern must be a string")
            if _NON_RE2.search(pattern):
                raise PaneIRError(f"{where}: pattern {pattern!r} uses lookaround or backreferences, which RE2 cannot run")
            try:
                re.compile(pattern)
            except re.error as error:
                raise PaneIRError(f"{where}: pattern {pattern!r} does not compile: {error}") from error
        return Str(tuple(enum), _int(schema, "minLength", where), _int(schema, "maxLength", where), pattern)
    if kind == "boolean":
        _reject_unknown(schema, {"type"}, where)
        return Bool()
    if kind == "number":
        _reject_unknown(schema, {"type", "format", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}, where)
        return Num(
            _number(schema, "minimum", where),
            _number(schema, "maximum", where),
            _number(schema, "exclusiveMinimum", where),
            _number(schema, "exclusiveMaximum", where),
        )
    if kind == "integer":
        _reject_unknown(schema, {"type", "format", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"}, where)
        fmt = schema.get("format", "int64")
        if fmt not in _INT_FORMATS:
            raise PaneIRError(f"{where}: integer format {fmt!r} is not supported")
        go_type, lo, hi = _INT_FORMATS[fmt]
        bounds = []
        for key, shift in (("minimum", 0), ("exclusiveMinimum", 1), ("maximum", 0), ("exclusiveMaximum", -1)):
            value = _number(schema, key, where)
            if value is not None:
                if value != int(value):
                    raise PaneIRError(f"{where}: integer {key} must be an integer")
                value = int(value) + shift
            bounds.append(value)
        minimum = max((b for b in bounds[:2] if b is not None), default=None)
        maximum = min((b for b in bounds[2:] if b is not None), default=None)
        if lo is not None:
            minimum = lo if minimum is None else max(minimum, lo)
        if hi is not None:
            maximum = hi if maximum is None else min(maximum, hi)
        if go_type.startswith("uint") and minimum not in (None, 0):
            # Validate as a signed range; values above int64 are refused.
            go_type = "int64"
        return Int(go_type, minimum, maximum)
    if kind == "array":
        _reject_unknown(schema, {"type", "items", "minItems", "maxItems"}, where)
        items = normalize(schema["items"], f"{where}.items") if "items" in schema else Any_()
        return Array(items, _int(schema, "minItems", where), _int(schema, "maxItems", where))
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
            if additional is False:
                return Object((), closed=True)
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
    aliases: tuple[str, ...] = ()
    paths: tuple[str, ...] = ()
    mcp_expose: str = "never"
    mcp_group: str | None = None
    cli_path: str | None = None
    cli_visible: bool = False
    cli_positional: tuple[str, ...] = ()
    secret_output: bool = False
    risk: str = "read"
    gesture: bool = False
    scope_class: str = "standard"
    server_only: bool = False

    @property
    def mcp(self) -> dict[str, str]:
        out = {"expose": self.mcp_expose}
        if self.mcp_group is not None:
            out["group"] = self.mcp_group
        return out

    @property
    def mcp_tool(self) -> str:
        return mcp_tool_name(self.name)


def mcp_tool_name(op: str) -> str:
    """The MCP tool name of an op: '.' and '-' become '_' (decision 21)."""

    return op.replace(".", "_").replace("-", "_")


_MCP_EXPOSE = {"default", "opt_in", "never"}

# Decision 27: the exact risk enum of cmux-app-host's
# schema/v2/cmux-app-catalog.schema.json.
RISKS = ("read", "mutate-own", "mutate-shared", "execute", "send-external", "destructive")

# The app platform's scope class table. emit-ir compiles the same file in;
# a third party outside this repo passes its own copy (--scope-classes).
DEFAULT_SCOPE_CLASSES = (
    Path(__file__).resolve().parents[3] / "crates" / "cmux-app-host" / "schema" / "v2" / "scope-classes.json"
)


class ScopeClasses:
    """First-matching-rule scope classifier over scope-classes.json."""

    def __init__(self, text: str):
        table = json.loads(text)
        rules = table.get("rules")
        if not isinstance(rules, list):
            raise PaneIRError("scope-classes.json has no rules")
        self.rules = []
        for rule in rules:
            try:
                self.rules.append((re.compile(rule["pattern"]), rule["class"], bool(rule.get("serverOnly", False))))
            except (KeyError, TypeError, re.error) as error:
                raise PaneIRError(f"scope-classes.json: bad rule {rule!r}: {error}") from error

    @classmethod
    def load(cls, path: str | Path | None = None) -> "ScopeClasses":
        return cls(Path(path or DEFAULT_SCOPE_CLASSES).read_text(encoding="utf-8"))

    def classify(self, scope: str) -> tuple[str, bool]:
        for pattern, klass, server_only in self.rules:
            if pattern.search(scope):
                return klass, server_only
        raise PaneIRError(f"scope {scope!r} matches no rule in scope-classes.json")
_CLI_PATH = re.compile(r"^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*){0,2}$")
MCP_TOOL_MAX = 48


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
    methods: tuple[str, ...]
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


def file_sha256(text: str) -> str:
    """Lowercase hex SHA-256 of the IR file's bytes (HelloIr.sha256)."""

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _load_json(text: str, what: str) -> dict[str, Any]:
    try:
        document = json.loads(text, object_pairs_hook=_no_dupes, parse_constant=_reject_constant)
    except json.JSONDecodeError as error:
        raise PaneIRError(f"{what} is not JSON: {error}") from error
    if not isinstance(document, dict):
        raise PaneIRError(f"{what} must be an object")
    return document


def merge_fragment(base: dict[str, Any], fragment: dict[str, Any]) -> dict[str, Any]:
    """Return base plus one third-party app's catalog fragment (decision 14).

    A fragment adds only app-owned namespaces that the base does not declare,
    plus their ops, events and types. Type names must not collide. Everything
    else (ops outside the fragment's namespaces, owners, aliases that shadow
    an op) is then checked by parse.
    """

    merged = {key: (list(value) if isinstance(value, list) else dict(value) if isinstance(value, dict) else value)
              for key, value in base.items()}
    base_ns = {ns.get("name") for ns in base.get("namespaces", ())}
    for i, ns in enumerate(fragment.get("namespaces", ())):
        if not str(ns.get("owner", "")).startswith("app:"):
            raise PaneIRError(f"fragment namespaces[{i}]: a fragment may add only app-owned namespaces")
        if ns.get("name") in base_ns:
            raise PaneIRError(f"fragment namespaces[{i}]: {ns.get('name')!r} is already declared")
    extra = sorted(set(fragment) - {"namespaces", "ops", "events", "types", "interfaces", "version", "$schema"})
    if extra:
        raise PaneIRError(f"fragment has unsupported keys {extra}")
    for key in ("namespaces", "ops", "events", "interfaces"):
        merged[key] = list(base.get(key, ())) + list(fragment.get(key, ()))
    types = dict(base.get("types", {}))
    for name, schema in fragment.get("types", {}).items():
        if name in types:
            raise PaneIRError(f"fragment type {name!r} collides with an existing type")
        types[name] = schema
    merged["types"] = types
    # Each fragment op must sit in a namespace (new or existing) whose owner
    # equals the op's owner; _parse_document checks that.
    for i, op in enumerate(fragment.get("ops", ())):
        if "owner" not in op:
            raise PaneIRError(f"fragment ops[{i}]: a fragment op must declare its owner")
        for derived in ("scope_class", "server_only"):
            if derived in op:
                raise PaneIRError(f"fragment ops[{i}]: {derived} is derived and may not be declared")
    return merged


def _split(name: str, namespaces: list[str], where: str) -> tuple[str, tuple[str, ...]]:
    owner = max((ns for ns in namespaces if name.startswith(ns + ".")), key=len, default=None)
    if owner is None:
        raise PaneIRError(f"{where}: {name!r} is outside every declared namespace")
    local = tuple(name[len(owner) + 1 :].split("."))
    if len(local) < 2 or not all(_SEGMENT.match(s) for s in local):
        raise PaneIRError(f"{where}: {name!r} must be <namespace>.<family>.<verb>")
    return owner, local


def load_pane_ir(
    path: str | Path, fragment: str | Path | None = None, scope_classes: ScopeClasses | None = None
) -> PaneIR:
    """Load the IR, optionally with one third-party fragment merged in.

    With a fragment, the IR's sha256 and version are the fragment's: that is
    what a third-party provider names in its hello.
    """

    raw = Path(path).read_text(encoding="utf-8")
    if fragment is None:
        return parse_pane_ir(raw, scope_classes)
    fragment_raw = Path(fragment).read_text(encoding="utf-8")
    return parse_pane_ir_with_fragment(raw, fragment_raw, scope_classes)


def parse_pane_ir_with_fragment(text: str, fragment_text: str, scope_classes: ScopeClasses | None = None) -> PaneIR:
    base = _load_json(text, "IR")
    fragment = _load_json(fragment_text, "fragment")
    merged = merge_fragment(base, fragment)
    return _parse_document(
        merged,
        sha256=file_sha256(fragment_text),
        version=str(fragment.get("version", base.get("version"))),
        scope_classes=scope_classes,
    )


def parse_pane_ir(text: str, scope_classes: ScopeClasses | None = None) -> PaneIR:
    document = _load_json(text, "IR")
    return _parse_document(
        document, sha256=file_sha256(text), version=str(document.get("version")), scope_classes=scope_classes
    )


def _parse_document(
    document: dict[str, Any], *, sha256: str, version: str, scope_classes: ScopeClasses | None = None
) -> PaneIR:
    classes = scope_classes or ScopeClasses.load()
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

    def secret_reachable(schema: Any, seen: set[str]) -> bool:
        """True when a property reachable from schema has x-cmux-secret: true."""

        if isinstance(schema, dict):
            if schema.get("x-cmux-secret") is True:
                return True
            ref = schema.get("$ref")
            if isinstance(ref, str):
                name = _ref_name(ref, "secret_output")
                if name in seen or name not in types_doc:
                    return False
                return secret_reachable(types_doc[name], seen | {name})
            return any(secret_reachable(v, seen) for k, v in schema.items() if k not in _ANNOTATIONS)
        if isinstance(schema, list):
            return any(secret_reachable(v, seen) for v in schema)
        return False

    def top_level_props(schema: Any) -> dict[str, Any]:
        seen: set[str] = set()
        while isinstance(schema, dict) and "$ref" in schema:
            name = _ref_name(schema["$ref"], "params")
            if name in seen:
                break
            seen.add(name)
            schema = types_doc.get(name, {})
        if isinstance(schema, dict) and isinstance(schema.get("properties"), dict):
            return schema["properties"]
        return {}

    def is_string_schema(schema: Any) -> bool:
        if not isinstance(schema, dict):
            return False
        t = schema.get("type")
        if t == "string" or (isinstance(t, list) and "string" in t):
            return True
        return any(is_string_schema(o) for o in schema.get("anyOf", ()) + schema.get("oneOf", ()))

    ops: list[Op] = []
    for i, entry in enumerate(document["ops"]):
        where = f"ops[{i}]"
        name = entry.get("name")
        if not isinstance(name, str):
            raise PaneIRError(f"{where}: missing name")
        ns, local = _split(name, ns_names, where)
        kind = entry.get("kind")
        if kind not in _KINDS:
            raise PaneIRError(f"{where}: kind must be read, mutation or stream")
        owner = entry.get("owner")
        ns_owner = next(n.owner for n in namespaces if n.name == ns)
        if owner is not None and owner != ns_owner:
            raise PaneIRError(f"{where}: {name!r} is owned by {owner!r} but namespace {ns!r} belongs to {ns_owner!r}")
        aliases = tuple(entry.get("aliases", ()))
        if any(not isinstance(a, str) or not _NS.match(a) for a in aliases):
            raise PaneIRError(f"{where}: aliases must be dotted lowercase names")
        if aliases and ns_owner != "first-party":
            # Decision 18: aliases exist only for first-party wire compatibility.
            raise PaneIRError(f"{where}: a third-party op may not declare aliases")
        params_props = top_level_props(entry.get("params", {}))
        paths = entry.get("paths", [])
        if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
            raise PaneIRError(f"{where}: paths must be a list of param names")
        for param in paths:
            if param not in params_props:
                raise PaneIRError(f"{where}: paths entry {param!r} is not a top-level param")
            if not is_string_schema(params_props[param]):
                raise PaneIRError(f"{where}: paths entry {param!r} is not a string param")
        mcp = entry.get("mcp", {"expose": "never"})
        if (
            not isinstance(mcp, dict)
            or set(mcp) - {"expose", "group"}
            or mcp.get("expose") not in _MCP_EXPOSE
            or ("group" in mcp and (not isinstance(mcp["group"], str) or not mcp["group"]))
        ):
            raise PaneIRError(f"{where}: mcp must be {{expose: default|opt_in|never, group?: non-empty string}}")
        cli = entry.get("cli")
        cli_positional: tuple[str, ...] = ()
        if cli is not None:
            if (
                not isinstance(cli, dict)
                or set(cli) - {"path", "visible", "positional"}
                or not isinstance(cli.get("path"), str)
                or not _CLI_PATH.match(cli["path"])
                or not isinstance(cli.get("visible"), bool)
            ):
                raise PaneIRError(f"{where}: cli must be {{path: '<verb>[ <verb>]', visible: bool, positional?: [param]}}")
            cli_positional = tuple(cli.get("positional", ()))
            for param in cli_positional:
                if param not in params_props:
                    raise PaneIRError(f"{where}: cli positional {param!r} is not a top-level param")
        scope = entry.get("scope")
        if not isinstance(scope, str) or not scope:
            raise PaneIRError(f"{where}: missing scope")
        risk = entry.get("risk")
        if risk not in RISKS:
            raise PaneIRError(f"{where}: risk must be one of {', '.join(RISKS)}")
        gesture = entry.get("gesture")
        if not isinstance(gesture, bool):
            raise PaneIRError(f"{where}: gesture must be a boolean")
        scope_class, server_only = classes.classify(scope)
        # emit-ir output carries the derived fields; they must agree with the
        # table this generator uses (a stale IR or table is refused).
        # (emit-ir writes scope_class always and server_only only when true;
        # fragments may carry neither and get them derived.)
        if "scope_class" in entry and entry["scope_class"] != scope_class:
            raise PaneIRError(f"{where}: scope_class {entry['scope_class']!r} but the table gives {scope_class!r}")
        if ("scope_class" in entry or "server_only" in entry) and entry.get("server_only", False) != server_only:
            raise PaneIRError(f"{where}: server_only {entry.get('server_only', False)!r} but the table gives {server_only!r}")
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
                aliases,
                tuple(paths),
                mcp["expose"],
                mcp.get("group"),
                cli["path"] if cli else None,
                bool(cli["visible"]) if cli else False,
                cli_positional,
                # Derived; a declared value is overwritten (decision 21).
                secret_reachable(entry.get("result", {}), set()),
                risk,
                gesture,
                scope_class,
                server_only,
            )
        )
    tools: dict[str, str] = {}
    cli_paths: dict[tuple[str, str], str] = {}
    for op in ops:
        # Decision 23: the tool-name rules apply to every op, exposed or not.
        tool = op.mcp_tool
        if len(tool) > MCP_TOOL_MAX:
            raise PaneIRError(f"{op.name}: MCP tool name {tool!r} is longer than {MCP_TOOL_MAX}")
        if tool in tools:
            raise PaneIRError(f"{op.name} and {tools[tool]} have the same MCP tool name {tool!r}")
        tools[tool] = op.name
        if op.cli_path is not None:
            owner = next(n.owner for n in namespaces if n.name == op.namespace)
            key = (owner, op.cli_path)
            if key in cli_paths:
                raise PaneIRError(f"{op.name} and {cli_paths[key]} have the same cli path {op.cli_path!r}")
            cli_paths[key] = op.name

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

    # Interfaces: the cmux-app-host shape {name, methods{}, events[]} (Rust
    # lane R9) or the seed shape {name, ops[], events[]}. Only names are used.
    # Aliases (decision 18): first party only; never the name of an op, an
    # event or another alias.
    taken: dict[str, str] = {op.name: op.name for op in ops}
    taken.update({ev.name: ev.name for ev in events})
    for op in ops:
        for alias in op.aliases:
            if alias in taken:
                raise PaneIRError(f"{op.name}: alias {alias!r} names an existing op, event or alias ({taken[alias]})")
            taken[alias] = op.name

    interfaces = tuple(
        Interface(e["name"], tuple(sorted(e.get("methods", {}))) or tuple(e.get("ops", ())), tuple(e.get("events", ())))
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
        elif isinstance(node, Union):
            for _, variant in node.variants:
                check_refs(variant, where)

    for name, node in types.items():
        check_refs(node, f"types.{name}")
    for op in ops:
        check_refs(op.params, op.name)
        check_refs(op.result, op.name)
    for ev in events:
        check_refs(ev.data, ev.name)

    return PaneIR(
        version=version,
        sha256=sha256,
        namespaces=tuple(namespaces),
        ops=tuple(ops),
        events=tuple(events),
        interfaces=interfaces,
        types=types,
    )
