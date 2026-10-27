"""Framed-IPC method attributes of the SDK schema and their validation rules.

The attributes give every command and event what the framed transport needs
without parsing a payload: a wire id scoped to a family (Mojo scopes ordinals
per interface, mojo/public/tools/bindings/README.md), a priority taken from the
daemon's own table, an ordering domain, and the bounds of binary layouts
(Mojo validates every message before dispatch; an unbounded field cannot be
validated). spec/transports.md, "Framed IPC method attributes", is the contract.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from typing import Any

JsonObject = Mapping[str, Any]

# Family id ranges (one byte). method_id / event_id = family << 8 | ordinal.
COMMAND_FAMILY_RANGE = range(0x01, 0x60)
RESOURCE_V2_FAMILY_RANGE = range(0x60, 0xC0)
EVENT_FAMILY_RANGE = range(0xC0, 0xFF)

PRIORITIES = ("input", "control", "bulk", "background")
ORDERINGS = ("sequence", "independent")
DURABILITIES = ("read_only", "memory", "reply_before_journal", "reply_after_journal")
PAYLOADS = ("json", "binary")
CLIENTS = ("macos", "ios", "cli", "sdk")

# The frame header carries len as u32 capped at 32 MiB (p05-ipc design 3.2).
MAX_FRAME_BYTES = 32 * 1024 * 1024
LAYOUT_VERSION_RANGE = range(1, 0x100)

# Request fields that name a surface, a terminal or an attached view: such a
# command can pass input already queued on that surface's stream unless it is
# stream-scoped or says why crossing is safe.
STREAM_TARGET_FIELDS = frozenset(
    {"surface", "surfaces", "terminal", "terminal_id", "terminal_ids", "view"}
)

COMMAND_ATTRIBUTES = frozenset(
    {
        "method_id",
        "priority",
        "priority_changed_reason",
        "ordering",
        "durability",
        "payload",
        "layout_version",
        "stream_scoped",
        "crosses_stream_ok",
        "max_bytes",
        "spawns_terminal",
        "coalesce",
        "urgent",
        "clients",
    }
)
EVENT_ATTRIBUTES = frozenset({"event_id", "priority", "priority_changed_reason", "coalesce"})
FIELD_ATTRIBUTES = frozenset({"omit_nil", "max_bytes"})

_FAMILY_NAME = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
_NUMERIC_SCALARS = frozenset(
    {"int32", "uint16", "uint32", "int64", "uint64", "float32", "float64"}
)
_INTEGER_RANGES = {
    "int32": (-(2**31), 2**31 - 1),
    "uint16": (0, 2**16 - 1),
    "uint32": (0, 2**32 - 1),
    "int64": (-(2**63), 2**63 - 1),
    "uint64": (0, 2**64 - 1),
}
_RESOLVE_DEPTH = 32
# A family has ordinals 0-255; next_ordinal 256 means the family is full.
_ORDINALS = 0x100


def family_kind(family_id: int) -> str | None:
    """Return ``command`` or ``event`` for an sdk-schema family id, else None."""

    if family_id in COMMAND_FAMILY_RANGE:
        return "command"
    if family_id in EVENT_FAMILY_RANGE:
        return "event"
    return None


def split_wire_id(wire_id: int) -> tuple[int, int]:
    """Split a method_id or event_id into (family, ordinal)."""

    return wire_id >> 8, wire_id & 0xFF


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _text(node: JsonObject, key: str) -> str | None:
    """Return ``node[key]`` when it is a string; malformed values are reported elsewhere."""

    value = node.get(key)
    return value if isinstance(value, str) else None


class IpcMetaValidator:
    """Checks the IPC attributes of one decoded sdk-schema document."""

    def __init__(self, issue: Callable[[str, str], None], types: Any):
        self.issue = issue
        self.types: JsonObject = types if isinstance(types, Mapping) else {}
        self.family_ids: dict[int, str] = {}
        self.next_ordinals: dict[int, int] = {}
        # Declaring $.families opts the document into framed IPC: from then on
        # every command and event has a wire id and a priority (queue Q6).
        self.framed = False
        self.wire_ids: dict[str, dict[int, str]] = {"command": {}, "event": {}}

    # Type resolution -------------------------------------------------------

    def resolve(self, expression: Any) -> JsonObject | None:
        """Follow refs and aliases to a structural type, or None if unknown."""

        for _ in range(_RESOLVE_DEPTH):
            if not isinstance(expression, Mapping):
                return None
            kind = _text(expression, "kind")
            if kind == "ref":
                name = _text(expression, "name")
                if name is None:
                    return None
                expression = self.types.get(name)
            elif kind == "alias":
                expression = expression.get("target")
            else:
                return expression
        return None

    def _scalar_name(self, expression: Any) -> str | None:
        resolved = self.resolve(expression)
        if resolved is None or resolved.get("kind") != "scalar":
            return None
        return _text(resolved, "name")

    def _is_string(self, expression: Any) -> bool:
        return self._scalar_name(expression) == "string"

    def _is_string_array(self, expression: Any) -> bool:
        resolved = self.resolve(expression)
        return (
            resolved is not None
            and resolved.get("kind") == "array"
            and self._is_string(resolved.get("items"))
        )

    def _is_numeric(self, expression: Any) -> bool:
        return self._scalar_name(expression) in _NUMERIC_SCALARS

    # Families --------------------------------------------------------------

    def families(self, value: Any) -> None:
        path = "$.families"
        self.framed = True
        if not isinstance(value, Mapping):
            self.issue(path, "must be an object")
            return
        for name in sorted(value):
            entry_path = f"{path}.{name}"
            if not isinstance(name, str) or not _FAMILY_NAME.fullmatch(name):
                self.issue(entry_path, "family name must be kebab-case")
            entry = value[name]
            if not isinstance(entry, Mapping):
                self.issue(entry_path, "must be an object")
                continue
            for key in sorted(set(entry) - {"id", "description", "next_ordinal"}):
                self.issue(f"{entry_path}.{key}", "unknown key")
            next_ordinal = entry.get("next_ordinal")
            if "next_ordinal" in entry and (
                not _is_int(next_ordinal) or not 0 <= next_ordinal <= _ORDINALS
            ):
                self.issue(f"{entry_path}.next_ordinal", f"must be an integer 0-{_ORDINALS}")
                next_ordinal = None
            description = entry.get("description")
            if not isinstance(description, str) or not description:
                self.issue(f"{entry_path}.description", "must be a non-empty string")
            family_id = entry.get("id")
            if not _is_int(family_id):
                self.issue(f"{entry_path}.id", "must be an integer")
                continue
            if family_id in RESOURCE_V2_FAMILY_RANGE:
                self.issue(
                    f"{entry_path}.id",
                    "0x60-0xBF is reserved for resource-operations-v2 families",
                )
                continue
            if family_kind(family_id) is None:
                self.issue(
                    f"{entry_path}.id",
                    "must be a command family (0x01-0x5F) or an event family (0xC0-0xFE)",
                )
                continue
            if family_id in self.family_ids:
                self.issue(
                    f"{entry_path}.id",
                    f"duplicates family {self.family_ids[family_id]!r} (0x{family_id:02X})",
                )
                continue
            self.family_ids[family_id] = name
            if next_ordinal is not None:
                self.next_ordinals[family_id] = next_ordinal

    def wire_id(self, value: Any, path: str, *, kind: str, owner: str) -> None:
        if not _is_int(value) or not 0 <= value <= 0xFFFF:
            self.issue(path, "must be a u16 (family << 8 | ordinal)")
            return
        family_id, ordinal = split_wire_id(value)
        family = self.family_ids.get(family_id)
        if family is None:
            self.issue(path, f"family 0x{family_id:02X} is not declared in $.families")
            return
        if family_kind(family_id) != kind:
            self.issue(
                path,
                f"0x{value:04X} is outside the {kind} family range "
                f"(family {family!r} is a {family_kind(family_id)} family)",
            )
            return
        next_ordinal = self.next_ordinals.get(family_id)
        if next_ordinal is not None and ordinal >= next_ordinal:
            self.issue(
                path,
                f"ordinal {ordinal} of 0x{value:04X} is not below family {family!r} "
                f"next_ordinal {next_ordinal}",
            )
            return
        existing = self.wire_ids[kind].get(value)
        if existing is not None:
            self.issue(
                path,
                f"duplicate id 0x{value:04X} in family {family!r} (also {existing!r})",
            )
            return
        self.wire_ids[kind][value] = owner

    # Commands and events ---------------------------------------------------

    def _enum(self, node: JsonObject, key: str, path: str, allowed: Sequence[str]) -> None:
        if key in node and node[key] not in allowed:
            self.issue(f"{path}.{key}", f"must be one of {', '.join(allowed)}")

    def _boolean(self, node: JsonObject, key: str, path: str) -> None:
        if key in node and not isinstance(node[key], bool):
            self.issue(f"{path}.{key}", "must be a boolean")

    def _reason(self, node: JsonObject, key: str, path: str) -> None:
        if key in node and (not isinstance(node[key], str) or not node[key].strip()):
            self.issue(f"{path}.{key}", "must be a non-empty reason")

    def _priority(self, node: JsonObject, path: str) -> None:
        self._enum(node, "priority", path, PRIORITIES)
        self._reason(node, "priority_changed_reason", path)
        if "priority_changed_reason" in node and "priority" not in node:
            self.issue(f"{path}.priority_changed_reason", "needs priority")

    def command(self, name: str, node: JsonObject, path: str) -> None:
        if not self.framed and not COMMAND_ATTRIBUTES & set(node):
            return
        if "method_id" not in node:
            self.issue(path, "IPC attributes need method_id")
        else:
            self.wire_id(node["method_id"], f"{path}.method_id", kind="command", owner=name)
        if "priority" not in node:
            self.issue(path, "IPC attributes need priority")
        if "durability" not in node:
            self.issue(path, "IPC attributes need durability")
        self._priority(node, path)
        self._enum(node, "ordering", path, ORDERINGS)
        self._enum(node, "durability", path, DURABILITIES)
        self._enum(node, "payload", path, PAYLOADS)
        for key in ("stream_scoped", "spawns_terminal", "urgent"):
            self._boolean(node, key, path)
        self._reason(node, "crosses_stream_ok", path)
        if "max_bytes" in node:
            self._max_bytes(node["max_bytes"], f"{path}.max_bytes")
        if "clients" in node:
            self._clients(node["clients"], f"{path}.clients")
        request = node.get("request")
        request_fields = self._object_fields(request)
        if "coalesce" in node:
            self._coalesce(node["coalesce"], request_fields, f"{path}.coalesce")

        stream_scoped = node.get("stream_scoped") is True
        crosses = "crosses_stream_ok" in node
        if stream_scoped and crosses:
            self.issue(path, "stream_scoped and crosses_stream_ok exclude each other")
        if node.get("ordering") == "independent":
            if node.get("durability") != "read_only":
                self.issue(
                    f"{path}.ordering",
                    "independent ordering needs durability 'read_only'",
                )
            if stream_scoped:
                self.issue(f"{path}.ordering", "a stream-scoped command cannot be independent")
        targets = sorted(STREAM_TARGET_FIELDS & set(request_fields))
        if targets and not stream_scoped and not crosses:
            self.issue(
                path,
                f"targets a stream through {', '.join(targets)}: set stream_scoped "
                "or crosses_stream_ok with a reason",
            )
        if node.get("urgent") is True and node.get("priority") in ("bulk", "background"):
            self.issue(f"{path}.urgent", "urgent needs priority input or control")
        if node.get("spawns_terminal") is True and node.get("durability") == "read_only":
            self.issue(f"{path}.durability", "a terminal-spawning command is not read_only")

        layout = node.get("layout_version")
        if node.get("payload") == "binary":
            if layout is None:
                self.issue(path, "a binary payload needs layout_version")
            self.binary_layout(request, f"{path}.request")
            self.binary_layout(node.get("result"), f"{path}.result")
        elif "layout_version" in node:
            self.issue(f"{path}.layout_version", "needs payload 'binary'")
        if layout is not None and (not _is_int(layout) or layout not in LAYOUT_VERSION_RANGE):
            self.issue(f"{path}.layout_version", "must be an integer 1-255")

    def event(self, name: str, node: JsonObject, path: str) -> None:
        if not self.framed and not EVENT_ATTRIBUTES & set(node):
            return
        if "event_id" not in node:
            self.issue(path, "IPC attributes need event_id")
        else:
            self.wire_id(node["event_id"], f"{path}.event_id", kind="event", owner=name)
        if "priority" not in node:
            self.issue(path, "IPC attributes need priority")
        self._priority(node, path)
        if "coalesce" in node:
            self._coalesce(
                node["coalesce"], self._object_fields(node.get("payload")), f"{path}.coalesce"
            )

    def _object_fields(self, expression: Any) -> JsonObject:
        resolved = self.resolve(expression)
        if resolved is None or resolved.get("kind") != "object":
            return {}
        fields = resolved.get("fields")
        return fields if isinstance(fields, Mapping) else {}

    def _max_bytes(self, value: Any, path: str) -> None:
        if not _is_int(value) or not 1 <= value <= MAX_FRAME_BYTES:
            self.issue(path, f"must be an integer 1-{MAX_FRAME_BYTES}")

    def _clients(self, value: Any, path: str) -> None:
        if isinstance(value, (str, bytes)) or not isinstance(value, Sequence) or not value:
            self.issue(path, "must be a non-empty array")
            return
        if len(set(map(repr, value))) != len(value):
            self.issue(path, "must contain unique values")
        for index, client in enumerate(value):
            if client not in CLIENTS:
                self.issue(f"{path}[{index}]", f"must be one of {', '.join(CLIENTS)}")

    def _coalesce(self, value: Any, fields: JsonObject, path: str) -> None:
        if not isinstance(value, Mapping):
            self.issue(path, "must be an object")
            return
        for key in sorted(set(value) - {"key", "additive"}):
            self.issue(f"{path}.{key}", "unknown key")
        names: dict[str, list[str]] = {}
        for part in ("key", "additive"):
            raw = value.get(part, [])
            if isinstance(raw, (str, bytes)) or not isinstance(raw, Sequence):
                self.issue(f"{path}.{part}", "must be an array of field names")
                names[part] = []
                continue
            names[part] = [item for item in raw if isinstance(item, str)]
            if len(names[part]) != len(raw) or len(set(names[part])) != len(raw):
                self.issue(f"{path}.{part}", "must hold unique field names")
            for index, field in enumerate(names[part]):
                if field not in fields:
                    self.issue(f"{path}.{part}[{index}]", f"names unknown field {field!r}")
        for index, field in enumerate(names["additive"]):
            if field in names["key"]:
                self.issue(f"{path}.additive[{index}]", f"{field!r} is also a key field")
            elif isinstance(fields.get(field), Mapping) and not self._is_numeric(
                fields[field].get("type")
            ):
                # A field that is not an object is reported by validate_field.
                self.issue(f"{path}.additive[{index}]", f"{field!r} is not numeric")

    # Fields ----------------------------------------------------------------

    def field(self, field: JsonObject, path: str) -> None:
        if "omit_nil" in field:
            if not isinstance(field["omit_nil"], bool):
                self.issue(f"{path}.omit_nil", "must be a boolean")
            elif field["omit_nil"] and field.get("presence") == "required":
                self.issue(f"{path}.omit_nil", "a required field cannot be omitted")
        if "max_bytes" in field:
            # On an array of strings the bound applies to each item.
            self._max_bytes(field["max_bytes"], f"{path}.max_bytes")
            field_type = field.get("type")
            if not self._is_string(field_type) and not self._is_string_array(field_type):
                self.issue(f"{path}.max_bytes", "bounds string fields and arrays of strings only")
        if "default" in field:
            default = field["default"]
            if default is None:
                matches = field.get("nullable") is True
            else:
                matches = self.conforms(default, field.get("type"), _RESOLVE_DEPTH)
            if not matches:
                self.issue(f"{path}.default", "does not match the field type")

    def conforms(self, value: Any, expression: Any, depth: int) -> bool:
        resolved = self.resolve(expression)
        if resolved is None or depth == 0:
            return True  # Unknown references are reported elsewhere.
        kind = _text(resolved, "kind")
        if kind == "scalar":
            name = _text(resolved, "name")
            if name == "string":
                return isinstance(value, str)
            if name == "boolean":
                return isinstance(value, bool)
            if name in _INTEGER_RANGES:
                low, high = _INTEGER_RANGES[name]
                return _is_int(value) and low <= value <= high
            return _is_int(value) or isinstance(value, float)
        if kind == "literal":
            return value == resolved.get("value") and type(value) is type(resolved.get("value"))
        if kind == "enum":
            options = resolved.get("values")
            if not isinstance(options, list):
                return True  # A malformed enum is reported by validate_type.
            return any(value == option and type(value) is type(option) for option in options)
        if kind == "array":
            return isinstance(value, list) and all(
                self.conforms(item, resolved.get("items"), depth - 1) for item in value
            )
        if kind == "map":
            return isinstance(value, Mapping) and all(
                self.conforms(item, resolved.get("values"), depth - 1)
                for item in value.values()
            )
        if kind in ("object", "tagged_union"):
            return isinstance(value, Mapping)
        if kind == "untagged_union":
            variants = resolved.get("variants")
            if not isinstance(variants, list):
                return True  # A malformed union is reported by validate_type.
            return any(self.conforms(value, variant, depth - 1) for variant in variants)
        return True  # opaque_json

    # Binary layouts --------------------------------------------------------

    def binary_layout(
        self,
        expression: Any,
        path: str,
        *,
        bound: Any = None,
        seen: frozenset[str] = frozenset(),
    ) -> None:
        """Require every length-prefixed part of a binary layout to be bounded."""

        while isinstance(expression, Mapping) and _text(expression, "kind") in ("ref", "alias"):
            if expression["kind"] == "alias":
                expression = expression.get("target")
                continue
            name = _text(expression, "name")
            if name is None:
                return  # A malformed ref is reported by validate_type.
            if name in seen:
                self.issue(path, f"recursive type {name!r} has no bounded binary layout")
                return
            seen = seen | {name}
            expression = self.types.get(name)
        if not isinstance(expression, Mapping):
            return  # Unknown references are reported elsewhere.
        kind = _text(expression, "kind")
        if kind == "scalar":
            if expression.get("name") == "string" and bound is None:
                self.issue(path, "a binary string field needs max_bytes")
        elif kind == "object":
            if expression.get("additional_properties") is True:
                self.issue(path, "a binary object cannot allow additional properties")
            fields = expression.get("fields")
            for field_name in sorted(fields if isinstance(fields, Mapping) else {}):
                field = fields[field_name]
                if isinstance(field, Mapping):
                    self.binary_layout(
                        field.get("type"),
                        f"{path}.fields.{field_name}",
                        bound=field.get("max_bytes"),
                        seen=seen,
                    )
        elif kind == "array":
            if "max_items" not in expression:
                self.issue(path, "a binary array needs max_items")
            # A field max_bytes on an array of strings bounds each item.
            self.binary_layout(expression.get("items"), f"{path}.items", bound=bound, seen=seen)
        elif kind == "tagged_union":
            variants = expression.get("variants")
            for variant in sorted(variants if isinstance(variants, Mapping) else {}):
                self.binary_layout(variants[variant], f"{path}.variants.{variant}", seen=seen)
        elif kind in ("map", "opaque_json", "untagged_union"):
            self.issue(path, f"{kind} has no bounded binary layout")
