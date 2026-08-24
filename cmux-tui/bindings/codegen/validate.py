"""Semantic validation for the SDK protocol IR."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

try:
    from .naming import find_collisions
except ImportError:  # Direct execution from this directory.
    from naming import find_collisions

JsonObject = Mapping[str, Any]

_TYPE_KINDS = frozenset(
    {
        "scalar",
        "literal",
        "enum",
        "object",
        "alias",
        "tagged_union",
        "untagged_union",
        "array",
        "map",
        "ref",
        "opaque_json",
    }
)
_SCALARS = frozenset(
    {
        "string",
        "boolean",
        "int32",
        "uint16",
        "uint32",
        "int64",
        "uint64",
        "float32",
        "float64",
    }
)
_STREAM_KINDS = frozenset({"subscribe", "attach"})
_EVENT_STREAMS = frozenset(
    {
        "subscribe",
        "subscribe-deltas",
        "attach-byte",
        "attach-render",
        "attach-browser",
    }
)
_EVENT_EMISSIONS = frozenset({"emitted", "serialized-never-emitted"})
_TYPE_NAME = re.compile(r"^[A-Z][A-Za-z0-9]*$")


@dataclass(frozen=True, slots=True)
class ValidationIssue:
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.message}"


class ValidationError(ValueError):
    """Raised when an SDK schema is structurally or semantically invalid."""

    def __init__(self, issues: Sequence[ValidationIssue]):
        self.issues = tuple(issues)
        lines = "\n".join(f"- {issue}" for issue in self.issues)
        super().__init__(f"invalid SDK schema:\n{lines}")


class _Validator:
    def __init__(self, document: JsonObject):
        self.document = document
        self.issues: list[ValidationIssue] = []
        self.type_names: set[str] = set()
        self.profile_names: set[str] = set()
        self.references: list[tuple[str, str]] = []
        self.event_names: set[str] = set()
        self.protocol_version: int | None = None
        self.strict = isinstance(document.get("protocol"), Mapping)

    def issue(self, path: str, message: str) -> None:
        self.issues.append(ValidationIssue(path, message))

    def require_mapping(self, value: Any, path: str) -> JsonObject | None:
        if not isinstance(value, Mapping):
            self.issue(path, "must be an object")
            return None
        if not all(isinstance(key, str) for key in value):
            self.issue(path, "object keys must be strings")
            return None
        return value

    def require_array(self, value: Any, path: str) -> Sequence[Any] | None:
        if isinstance(value, (str, bytes, bytearray)) or not isinstance(value, Sequence):
            self.issue(path, "must be an array")
            return None
        return value

    def require_nonempty_string(self, value: Any, path: str) -> str | None:
        if not isinstance(value, str) or not value:
            self.issue(path, "must be a non-empty string")
            return None
        return value

    def require_integer(
        self, value: Any, path: str, *, minimum: int | None = None
    ) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int):
            self.issue(path, "must be an integer")
            return None
        if minimum is not None and value < minimum:
            self.issue(path, f"must be at least {minimum}")
            return None
        return value

    def validate_keys(
        self,
        node: JsonObject,
        path: str,
        *,
        required: set[str] | frozenset[str] = frozenset(),
        allowed: set[str] | frozenset[str],
    ) -> None:
        if not self.strict:
            return
        for key in sorted(required - set(node)):
            self.issue(path, f"missing required key {key!r}")
        for key in sorted(set(node) - allowed):
            self.issue(f"{path}.{key}", "unknown key")

    def validate_unique(self, values: Sequence[Any], path: str) -> None:
        fingerprints = [
            json.dumps(value, ensure_ascii=False, sort_keys=True, default=repr)
            for value in values
        ]
        if len(set(fingerprints)) != len(fingerprints):
            self.issue(path, "must contain unique values")

    def validate(self) -> None:
        self.validate_root()
        for path, name in self.references:
            if name not in self.type_names:
                self.issue(path, f"references unknown type {name!r}")
        self.validate_profile_inheritance()
        self.raise_if_invalid()

    def validate_root(self) -> None:
        version = self.require_integer(
            self.document.get("schema_version"), "$.schema_version", minimum=1
        )
        if version is None:
            return

        mux_protocol = self.document.get("mux_protocol")
        protocol = self.document.get("protocol")
        self.validate_keys(
            self.document,
            "$",
            required={
                "$schema",
                "schema_version",
                "protocol",
                "profiles",
                "types",
                "commands",
                "events",
            },
            allowed={
                "$schema",
                "schema_version",
                "protocol",
                "profiles",
                "types",
                "commands",
                "events",
                "ir_sha256",
            },
        )
        if self.strict:
            if version != 2:
                self.issue("$.schema_version", "must equal 2")
            self.require_nonempty_string(self.document.get("$schema"), "$.$schema")
        if "ir_sha256" in self.document:
            digest = self.document["ir_sha256"]
            if not isinstance(digest, str) or not re.fullmatch(
                r"[0-9a-f]{64}", digest
            ):
                self.issue(
                    "$.ir_sha256",
                    "must be a lowercase 64-character SHA-256 digest",
                )
        if protocol is not None:
            protocol_object = self.require_mapping(protocol, "$.protocol")
            if protocol_object is not None:
                self.validate_keys(
                    protocol_object,
                    "$.protocol",
                    required={
                        "name",
                        "version",
                        "id_type",
                        "javascript_id_policy",
                    },
                    allowed={
                        "name",
                        "version",
                        "id_type",
                        "javascript_id_policy",
                    },
                )
                self.require_nonempty_string(protocol_object.get("name"), "$.protocol.name")
                self.protocol_version = self.require_integer(
                    protocol_object.get("version"), "$.protocol.version", minimum=1
                )
                if protocol_object.get("id_type") != "uint64":
                    self.issue("$.protocol.id_type", "must equal 'uint64'")
                self.require_nonempty_string(
                    protocol_object.get("javascript_id_policy"),
                    "$.protocol.javascript_id_policy",
                )
        if mux_protocol is not None:
            legacy_version = self.require_integer(
                mux_protocol, "$.mux_protocol", minimum=1
            )
            if self.protocol_version is None:
                self.protocol_version = legacy_version
            elif legacy_version is not None and legacy_version != self.protocol_version:
                self.issue(
                    "$.mux_protocol",
                    "must match $.protocol.version when both are present",
                )
        if self.protocol_version is None:
            self.issue("$", "must define mux_protocol or protocol.version")

        profiles = self.document.get("profiles", {})
        profile_object = self.require_mapping(profiles, "$.profiles")
        if profile_object is not None:
            self.profile_names = set(profile_object)
            for name in sorted(profile_object):
                self.validate_profile(name, profile_object[name])

        types = self.require_mapping(self.document.get("types"), "$.types")
        if types is not None:
            self.type_names = set(types)
            self.validate_name_collisions("$.types", self.type_names, style="pascal")
            for name in sorted(types):
                if not _TYPE_NAME.fullmatch(name):
                    self.issue(
                        f"$.types.{name}",
                        "type name must match ^[A-Z][A-Za-z0-9]*$",
                    )
                self.validate_type(types[name], f"$.types.{name}")

        events = self.document.get("events")
        event_entries = self.named_entries(events, "$.events")
        self.event_names = set(event_entries)
        self.validate_name_collisions("$.events", self.event_names, style="pascal")
        for name, event in event_entries.items():
            self.validate_event(name, event, f"$.events.{name}")

        commands = self.document.get("commands")
        command_entries = self.named_entries(commands, "$.commands")
        self.validate_name_collisions("$.commands", command_entries, style="snake")
        for name, command in command_entries.items():
            self.validate_command(name, command, f"$.commands.{name}")

    def named_entries(self, value: Any, path: str) -> dict[str, JsonObject]:
        if isinstance(value, Mapping):
            result: dict[str, JsonObject] = {}
            for name in sorted(value):
                if not isinstance(name, str) or not name:
                    self.issue(path, "entry names must be non-empty strings")
                    continue
                entry = self.require_mapping(value[name], f"{path}.{name}")
                if entry is not None:
                    result[name] = entry
            return result

        if self.strict:
            self.issue(path, "must be an object")
            return {}
        entries = self.require_array(value, path)
        if entries is None:
            return {}
        result = {}
        for index, raw_entry in enumerate(entries):
            entry_path = f"{path}[{index}]"
            entry = self.require_mapping(raw_entry, entry_path)
            if entry is None:
                continue
            name = next(
                (
                    entry.get(field)
                    for field in ("wire_name", "name", "command", "event")
                    if field in entry
                ),
                None,
            )
            name = self.require_nonempty_string(name, f"{entry_path}.wire_name")
            if name is None:
                continue
            if name in result:
                self.issue(entry_path, f"duplicate entry {name!r}")
            else:
                result[name] = entry
        return result

    def validate_name_collisions(
        self, path: str, names: Any, *, style: str
    ) -> None:
        collisions = find_collisions(names, style=style)
        for identifier, originals in collisions.items():
            self.issue(
                path,
                f"API name {identifier!r} collides for {', '.join(repr(x) for x in originals)}",
            )

    def validate_profile(self, name: str, value: Any) -> None:
        path = f"$.profiles.{name}"
        profile = self.require_mapping(value, path)
        if profile is None:
            return
        self.validate_keys(
            profile,
            path,
            required={"description", "inherits"},
            allowed={"description", "inherits", "transport", "requires_authority"},
        )
        self.require_nonempty_string(profile.get("description"), f"{path}.description")
        inherits = self.require_array(profile.get("inherits", []), f"{path}.inherits")
        if inherits is not None:
            self.validate_unique(inherits, f"{path}.inherits")
            for index, parent in enumerate(inherits):
                self.require_nonempty_string(parent, f"{path}.inherits[{index}]")
        if "transport" in profile:
            self.require_nonempty_string(profile["transport"], f"{path}.transport")
        if "requires_authority" in profile and not isinstance(
            profile["requires_authority"], bool
        ):
            self.issue(f"{path}.requires_authority", "must be a boolean")

    def validate_profile_inheritance(self) -> None:
        profiles = self.document.get("profiles", {})
        if not isinstance(profiles, Mapping):
            return
        edges: dict[str, tuple[str, ...]] = {}
        for name, raw_profile in profiles.items():
            if not isinstance(raw_profile, Mapping):
                continue
            raw_inherits = raw_profile.get("inherits", [])
            if not isinstance(raw_inherits, Sequence) or isinstance(raw_inherits, str):
                continue
            parents = tuple(parent for parent in raw_inherits if isinstance(parent, str))
            edges[name] = parents
            for index, parent in enumerate(parents):
                if parent not in profiles:
                    self.issue(
                        f"$.profiles.{name}.inherits[{index}]",
                        f"references unknown profile {parent!r}",
                    )

        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(name: str, chain: tuple[str, ...]) -> None:
            if name in visiting:
                cycle = " -> ".join((*chain, name))
                self.issue(f"$.profiles.{name}.inherits", f"inheritance cycle: {cycle}")
                return
            if name in visited:
                return
            visiting.add(name)
            for parent in edges.get(name, ()):
                if parent in edges:
                    visit(parent, (*chain, name))
            visiting.remove(name)
            visited.add(name)

        for name in sorted(edges):
            visit(name, ())

    def validate_type(self, value: Any, path: str) -> None:
        node = self.require_mapping(value, path)
        if node is None:
            return
        kind = self.require_nonempty_string(node.get("kind"), f"{path}.kind")
        if kind is None:
            return
        if kind not in _TYPE_KINDS:
            self.issue(f"{path}.kind", f"unknown type construct {kind!r}")
            return

        if kind == "scalar":
            self.validate_keys(
                node,
                path,
                required={"kind", "name"},
                allowed={"kind", "name"},
            )
            name = self.require_nonempty_string(node.get("name"), f"{path}.name")
            if name is not None and name not in _SCALARS:
                self.issue(
                    f"{path}.name",
                    f"must be one of {', '.join(sorted(_SCALARS))}",
                )
        elif kind == "literal":
            self.validate_keys(
                node,
                path,
                required={"kind", "value"},
                allowed={"kind", "value"},
            )
            if "value" not in node:
                self.issue(path, "literal must define value")
            elif isinstance(node["value"], (Mapping, Sequence)) and not isinstance(
                node["value"], str
            ):
                self.issue(f"{path}.value", "must be a JSON scalar or null")
        elif kind == "enum":
            self.validate_keys(
                node,
                path,
                required={"kind", "values"},
                allowed={"kind", "values"},
            )
            values = self.require_array(node.get("values"), f"{path}.values")
            if values is not None:
                if not values:
                    self.issue(f"{path}.values", "must not be empty")
                self.validate_unique(values, f"{path}.values")
                for index, enum_value in enumerate(values):
                    if enum_value is None or isinstance(
                        enum_value, (Mapping, Sequence)
                    ) and not isinstance(enum_value, str):
                        self.issue(
                            f"{path}.values[{index}]",
                            "must be a string, number, or boolean",
                        )
        elif kind == "object":
            self.validate_keys(
                node,
                path,
                required={"kind", "fields", "additional_properties"},
                allowed={"kind", "fields", "additional_properties", "constraints"},
            )
            fields = self.require_mapping(node.get("fields"), f"{path}.fields")
            if fields is not None:
                for field_name in sorted(fields):
                    self.validate_field(fields[field_name], f"{path}.fields.{field_name}")
            if "additional_properties" in node and not isinstance(
                node["additional_properties"], bool
            ):
                self.issue(f"{path}.additional_properties", "must be a boolean")
            self.validate_constraints(node.get("constraints", []), f"{path}.constraints")
        elif kind == "alias":
            self.validate_keys(
                node,
                path,
                required={"kind", "target"},
                allowed={"kind", "target"},
            )
            self.validate_type(node.get("target"), f"{path}.target")
        elif kind == "tagged_union":
            self.validate_keys(
                node,
                path,
                required={"kind", "tag", "variants"},
                allowed={"kind", "tag", "variants"},
            )
            self.require_nonempty_string(node.get("tag"), f"{path}.tag")
            variants = self.require_mapping(node.get("variants"), f"{path}.variants")
            if variants is not None:
                if not variants:
                    self.issue(f"{path}.variants", "must not be empty")
                for variant in sorted(variants):
                    self.validate_type(variants[variant], f"{path}.variants.{variant}")
        elif kind == "untagged_union":
            self.validate_keys(
                node,
                path,
                required={"kind", "variants"},
                allowed={"kind", "variants"},
            )
            variants = self.require_array(node.get("variants"), f"{path}.variants")
            if variants is not None:
                if len(variants) < 2:
                    self.issue(f"{path}.variants", "must contain at least two variants")
                for index, variant in enumerate(variants):
                    self.validate_type(variant, f"{path}.variants[{index}]")
        elif kind == "array":
            self.validate_keys(
                node,
                path,
                required={"kind", "items"},
                allowed={"kind", "items", "min_items", "max_items"},
            )
            self.validate_type(node.get("items"), f"{path}.items")
            self.validate_optional_bound(node, path, "min_items")
            self.validate_optional_bound(node, path, "max_items")
            minimum = node.get("min_items")
            maximum = node.get("max_items")
            if (
                isinstance(minimum, int)
                and not isinstance(minimum, bool)
                and isinstance(maximum, int)
                and not isinstance(maximum, bool)
                and minimum > maximum
            ):
                self.issue(path, "min_items must not exceed max_items")
        elif kind == "map":
            self.validate_keys(
                node,
                path,
                required={"kind", "values"},
                allowed={"kind", "values"},
            )
            self.validate_type(node.get("values"), f"{path}.values")
        elif kind == "ref":
            self.validate_keys(
                node,
                path,
                required={"kind", "name"},
                allowed={"kind", "name"},
            )
            name = self.require_nonempty_string(node.get("name"), f"{path}.name")
            if name is not None:
                if not _TYPE_NAME.fullmatch(name):
                    self.issue(
                        f"{path}.name",
                        "type name must match ^[A-Z][A-Za-z0-9]*$",
                    )
                self.references.append((f"{path}.name", name))
        elif kind == "opaque_json":
            self.validate_keys(
                node,
                path,
                required={"kind", "reason"},
                allowed={"kind", "reason"},
            )
            self.require_nonempty_string(node.get("reason"), f"{path}.reason")

    def validate_optional_bound(self, node: JsonObject, path: str, field: str) -> None:
        if field in node:
            self.require_integer(node[field], f"{path}.{field}", minimum=0)

    def validate_field(self, value: Any, path: str) -> None:
        field = self.require_mapping(value, path)
        if field is None:
            return
        self.validate_keys(
            field,
            path,
            required={"type", "presence", "nullable"},
            allowed={
                "type",
                "presence",
                "nullable",
                "since",
                "capability",
                "aliases",
                "default",
                "constraints",
                "description",
            },
        )
        self.validate_type(field.get("type"), f"{path}.type")
        if field.get("presence") not in {"required", "optional"}:
            self.issue(f"{path}.presence", "must be 'required' or 'optional'")
        if not isinstance(field.get("nullable"), bool):
            self.issue(f"{path}.nullable", "must be a boolean")
        aliases = field.get("aliases")
        if aliases is not None:
            alias_values = self.require_array(aliases, f"{path}.aliases")
            if alias_values is not None:
                self.validate_unique(alias_values, f"{path}.aliases")
                for index, alias in enumerate(alias_values):
                    self.require_nonempty_string(alias, f"{path}.aliases[{index}]")
        if "since" in field:
            self.require_integer(field["since"], f"{path}.since", minimum=1)
        if "capability" in field:
            self.require_nonempty_string(field["capability"], f"{path}.capability")
        if "description" in field and not isinstance(field["description"], str):
            self.issue(f"{path}.description", "must be a string")
        self.validate_constraints(field.get("constraints", []), f"{path}.constraints")

    def validate_constraints(self, value: Any, path: str) -> None:
        constraints = self.require_array(value, path)
        if constraints is None:
            return
        for index, constraint in enumerate(constraints):
            if isinstance(constraint, str):
                self.require_nonempty_string(constraint, f"{path}[{index}]")
            else:
                self.require_mapping(constraint, f"{path}[{index}]")

    def validate_versioned(self, node: JsonObject, path: str) -> None:
        since = self.require_integer(node.get("since"), f"{path}.since", minimum=1)
        if (
            since is not None
            and self.protocol_version is not None
            and since > self.protocol_version
        ):
            self.issue(
                f"{path}.since",
                f"must not exceed protocol version {self.protocol_version}",
            )
        capability = node.get("capability")
        if capability is not None:
            self.require_nonempty_string(capability, f"{path}.capability")

    def validate_command(self, name: str, value: JsonObject, path: str) -> None:
        if not name:
            self.issue(path, "wire name must be non-empty")
        self.validate_keys(
            value,
            path,
            required={
                "authority",
                "since",
                "capability",
                "request",
                "result",
                "stream",
                "constraints",
            },
            allowed={
                "authority",
                "since",
                "capability",
                "request",
                "result",
                "stream",
                "constraints",
            },
        )
        self.validate_versioned(value, path)
        authority = value.get("authority")
        if authority is not None:
            authority_name = self.require_nonempty_string(authority, f"{path}.authority")
            if (
                authority_name is not None
                and self.profile_names
                and authority_name not in self.profile_names
            ):
                self.issue(
                    f"{path}.authority",
                    f"references unknown profile {authority_name!r}",
                )
        elif self.profile_names:
            self.issue(f"{path}.authority", "is required")
        request = value.get("request")
        self.validate_type(request, f"{path}.request")
        if isinstance(request, Mapping) and request.get("kind") != "object":
            self.issue(f"{path}.request.kind", "command request must be an object")
        self.validate_type(value.get("result"), f"{path}.result")
        self.validate_constraints(value.get("constraints", []), f"{path}.constraints")
        stream = value.get("stream")
        if stream is not None:
            stream_object = self.require_mapping(stream, f"{path}.stream")
            if stream_object is not None:
                self.validate_keys(
                    stream_object,
                    f"{path}.stream",
                    required={"kind", "event_names", "ordering", "terminal_event"},
                    allowed={
                        "kind",
                        "event_names",
                        "mode_field",
                        "modes",
                        "ordering",
                        "terminal_event",
                    },
                )
                stream_kind = self.require_nonempty_string(
                    stream_object.get("kind"), f"{path}.stream.kind"
                )
                if stream_kind is not None and stream_kind not in _STREAM_KINDS:
                    self.issue(
                        f"{path}.stream.kind",
                        f"must be one of {', '.join(sorted(_STREAM_KINDS))}",
                    )
                names = stream_object.get("event_names", [])
                event_names = self.require_array(names, f"{path}.stream.event_names")
                if event_names is not None:
                    self.validate_unique(event_names, f"{path}.stream.event_names")
                    for index, event_name in enumerate(event_names):
                        event_name = self.require_nonempty_string(
                            event_name, f"{path}.stream.event_names[{index}]"
                        )
                        if (
                            event_name is not None
                            and self.event_names
                            and event_name not in self.event_names
                        ):
                            self.issue(
                                f"{path}.stream.event_names[{index}]",
                                f"references unknown event {event_name!r}",
                            )
                self.require_nonempty_string(
                    stream_object.get("ordering"), f"{path}.stream.ordering"
                )
                terminal_event = stream_object.get("terminal_event")
                if terminal_event is not None:
                    terminal_event = self.require_nonempty_string(
                        terminal_event, f"{path}.stream.terminal_event"
                    )
                    if (
                        terminal_event is not None
                        and self.event_names
                        and terminal_event not in self.event_names
                    ):
                        self.issue(
                            f"{path}.stream.terminal_event",
                            f"references unknown event {terminal_event!r}",
                        )
                    if (
                        terminal_event is not None
                        and isinstance(event_names, Sequence)
                        and terminal_event not in event_names
                    ):
                        self.issue(
                            f"{path}.stream.terminal_event",
                            "must also appear in event_names",
                        )
                if "mode_field" in stream_object:
                    self.require_nonempty_string(
                        stream_object["mode_field"], f"{path}.stream.mode_field"
                    )
                if "modes" in stream_object:
                    modes = self.require_mapping(
                        stream_object["modes"], f"{path}.stream.modes"
                    )
                    if modes is not None:
                        for mode in sorted(modes):
                            mode_events = self.require_array(
                                modes[mode], f"{path}.stream.modes.{mode}"
                            )
                            if mode_events is not None:
                                self.validate_unique(
                                    mode_events, f"{path}.stream.modes.{mode}"
                                )
                                for index, event_name in enumerate(mode_events):
                                    event_name = self.require_nonempty_string(
                                        event_name,
                                        f"{path}.stream.modes.{mode}[{index}]",
                                    )
                                    if (
                                        event_name is not None
                                        and self.event_names
                                        and event_name not in self.event_names
                                    ):
                                        self.issue(
                                            f"{path}.stream.modes.{mode}[{index}]",
                                            f"references unknown event {event_name!r}",
                                        )
                                    if (
                                        event_name is not None
                                        and isinstance(event_names, Sequence)
                                        and event_name not in event_names
                                    ):
                                        self.issue(
                                            f"{path}.stream.modes.{mode}[{index}]",
                                            "must also appear in event_names",
                                        )
                if ("mode_field" in stream_object) != ("modes" in stream_object):
                    self.issue(
                        f"{path}.stream",
                        "mode_field and modes must either both be present or both be absent",
                    )

    def validate_event(self, name: str, value: JsonObject, path: str) -> None:
        if not name:
            self.issue(path, "wire name must be non-empty")
        self.validate_keys(
            value,
            path,
            required={"since", "capability", "streams", "emission", "payload"},
            allowed={"since", "capability", "streams", "emission", "payload"},
        )
        self.validate_versioned(value, path)
        streams = self.require_array(value.get("streams", []), f"{path}.streams")
        if streams is not None:
            self.validate_unique(streams, f"{path}.streams")
            for index, stream in enumerate(streams):
                stream_name = self.require_nonempty_string(
                    stream, f"{path}.streams[{index}]"
                )
                if stream_name is not None and stream_name not in _EVENT_STREAMS:
                    self.issue(
                        f"{path}.streams[{index}]",
                        f"must be one of {', '.join(sorted(_EVENT_STREAMS))}",
                    )
        emission = self.require_nonempty_string(
            value.get("emission"), f"{path}.emission"
        )
        if emission is not None and emission not in _EVENT_EMISSIONS:
            self.issue(
                f"{path}.emission",
                f"must be one of {', '.join(sorted(_EVENT_EMISSIONS))}",
            )
        payload = value.get("payload")
        self.validate_type(payload, f"{path}.payload")
        if isinstance(payload, Mapping) and payload.get("kind") != "object":
            self.issue(f"{path}.payload.kind", "event payload must be an object")

    def raise_if_invalid(self) -> None:
        if self.issues:
            raise ValidationError(
                sorted(self.issues, key=lambda issue: (issue.path, issue.message))
            )


def validate_document(document: JsonObject) -> None:
    """Validate a decoded SDK schema or raise :class:`ValidationError`."""

    if not isinstance(document, Mapping):
        raise ValidationError((ValidationIssue("$", "must be an object"),))
    _Validator(document).validate()
