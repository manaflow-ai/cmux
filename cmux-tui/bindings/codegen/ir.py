"""Loading and immutable normalization of the SDK protocol IR."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

try:
    from .validate import ValidationError, ValidationIssue, validate_document
except ImportError:  # Direct execution from this directory.
    from validate import ValidationError, ValidationIssue, validate_document

JsonScalar = None | bool | int | float | str
JsonValue = JsonScalar | tuple["JsonValue", ...] | Mapping[str, "JsonValue"]
JsonObject = Mapping[str, JsonValue]


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value!r} is not allowed")


def _pairs_to_dict(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key {key!r}")
        result[key] = value
    return result


def _freeze(value: Any) -> JsonValue:
    if isinstance(value, Mapping):
        return MappingProxyType(
            {str(key): _freeze(value[key]) for key in sorted(value)}
        )
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return tuple(_freeze(item) for item in value)
    return value


def _thaw(value: JsonValue) -> Any:
    if isinstance(value, Mapping):
        return {key: _thaw(value[key]) for key in sorted(value)}
    if isinstance(value, tuple):
        return [_thaw(item) for item in value]
    return value


def _named_entries(value: Any, *, kind: str) -> dict[str, Any]:
    if isinstance(value, Mapping):
        return {name: value[name] for name in sorted(value)}
    result: dict[str, Any] = {}
    for entry in value:
        name = next(
            (
                entry.get(field)
                for field in ("wire_name", "name", kind)
                if field in entry
            ),
            None,
        )
        if name in result:
            raise ValidationError(
                (
                    ValidationIssue(
                        f"$.{kind}s",
                        f"duplicate normalized {kind} entry {name!r}",
                    ),
                )
            )
        result[name] = entry
    return {name: result[name] for name in sorted(result)}


def _canonical_json_bytes(document: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(
            document,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )


@dataclass(frozen=True, slots=True)
class SdkIR:
    """Validated, deeply immutable input consumed by language emitters."""

    schema_version: int
    mux_protocol: int
    ir_sha256: str
    types: JsonObject
    commands: JsonObject
    events: JsonObject
    profiles: JsonObject
    protocol: JsonObject
    document: JsonObject
    _canonical: bytes

    def type(self, name: str) -> JsonObject:
        return self._lookup(self.types, "type", name)

    def command(self, wire_name: str) -> JsonObject:
        return self._lookup(self.commands, "command", wire_name)

    def event(self, wire_name: str) -> JsonObject:
        return self._lookup(self.events, "event", wire_name)

    @staticmethod
    def _lookup(values: JsonObject, kind: str, name: str) -> JsonObject:
        try:
            value = values[name]
        except KeyError as error:
            raise KeyError(f"unknown {kind} {name!r}") from error
        if not isinstance(value, Mapping):
            raise TypeError(f"{kind} {name!r} is not an object")
        return value

    def canonical_bytes(self) -> bytes:
        """Return canonical semantic IR bytes used to compute ``ir_sha256``."""

        return self._canonical


def load_ir(path: str | Path) -> SdkIR:
    """Load, validate, normalize, and hash an SDK schema."""

    schema_path = Path(path)
    try:
        source = json.loads(
            schema_path.read_text(encoding="utf-8"),
            object_pairs_hook=_pairs_to_dict,
            parse_constant=_reject_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"cannot load SDK schema {schema_path}: {error}") from error
    return load_ir_document(source)


def load_ir_document(source: Mapping[str, Any]) -> SdkIR:
    """Validate and normalize an already decoded SDK schema."""

    validate_document(source)
    normalized = dict(source)
    normalized.pop("ir_sha256", None)
    normalized["types"] = {
        name: source["types"][name] for name in sorted(source["types"])
    }
    normalized["commands"] = _named_entries(source["commands"], kind="command")
    normalized["events"] = _named_entries(source["events"], kind="event")
    profiles = source.get("profiles", {})
    normalized["profiles"] = {name: profiles[name] for name in sorted(profiles)}

    raw_protocol = source.get("protocol")
    mux_protocol = (
        raw_protocol["version"]
        if isinstance(raw_protocol, Mapping)
        else source["mux_protocol"]
    )
    protocol = (
        dict(raw_protocol)
        if isinstance(raw_protocol, Mapping)
        else {"name": "cmux-tui-mux", "version": mux_protocol}
    )
    normalized["protocol"] = protocol
    normalized.pop("mux_protocol", None)

    canonical = _canonical_json_bytes(normalized)
    digest = hashlib.sha256(canonical).hexdigest()
    supplied_digest = source.get("ir_sha256")
    if supplied_digest is not None and supplied_digest != digest:
        raise ValidationError(
            (
                ValidationIssue(
                    "$.ir_sha256",
                    f"does not match derived SHA-256 {digest}",
                ),
            )
        )

    document_with_digest = dict(normalized)
    document_with_digest["ir_sha256"] = digest
    frozen_document = _freeze(document_with_digest)
    assert isinstance(frozen_document, Mapping)
    frozen_types = frozen_document["types"]
    frozen_commands = frozen_document["commands"]
    frozen_events = frozen_document["events"]
    frozen_profiles = frozen_document["profiles"]
    frozen_protocol = frozen_document["protocol"]
    assert isinstance(frozen_types, Mapping)
    assert isinstance(frozen_commands, Mapping)
    assert isinstance(frozen_events, Mapping)
    assert isinstance(frozen_profiles, Mapping)
    assert isinstance(frozen_protocol, Mapping)

    return SdkIR(
        schema_version=source["schema_version"],
        mux_protocol=mux_protocol,
        ir_sha256=digest,
        types=frozen_types,
        commands=frozen_commands,
        events=frozen_events,
        profiles=frozen_profiles,
        protocol=frozen_protocol,
        document=frozen_document,
        _canonical=canonical,
    )


def mutable_document(ir: SdkIR) -> dict[str, Any]:
    """Return a mutable JSON-compatible copy for specialized emitters."""

    value = _thaw(ir.document)
    assert isinstance(value, dict)
    return value
