from __future__ import annotations

import json
import re
from collections.abc import Mapping
from pathlib import PurePosixPath
from typing import Any

try:
    from .ir import SdkIR
    from .writer import Emitter
except ImportError:  # pragma: no cover - supports direct emitter imports.
    from ir import SdkIR  # type: ignore[no-redef]
    from writer import Emitter  # type: ignore[no-redef]


_SCALARS = {
    "string": "String",
    "boolean": "bool",
    "int32": "i32",
    "uint16": "u16",
    "uint32": "u32",
    "int64": "i64",
    "uint64": "u64",
    "float32": "f32",
    "float64": "f64",
}

_RUST_KEYWORDS = {
    "as",
    "async",
    "await",
    "break",
    "const",
    "continue",
    "crate",
    "dyn",
    "else",
    "enum",
    "extern",
    "false",
    "fn",
    "for",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mod",
    "move",
    "mut",
    "pub",
    "ref",
    "return",
    "self",
    "Self",
    "static",
    "struct",
    "super",
    "trait",
    "true",
    "try",
    "type",
    "union",
    "unsafe",
    "use",
    "where",
    "while",
    "yield",
}


def _plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_plain(item) for item in value]
    return value


def _words(value: str) -> list[str]:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    return [part.lower() for part in re.split(r"[^A-Za-z0-9]+", value) if part]


def _pascal(value: str) -> str:
    rendered = "".join(part[:1].upper() + part[1:] for part in _words(value))
    if not rendered:
        return "Value"
    if rendered[0].isdigit():
        return f"Value{rendered}"
    return rendered


def _snake(value: str) -> str:
    rendered = "_".join(_words(value)) or "value"
    if rendered[0].isdigit():
        rendered = f"value_{rendered}"
    if rendered in _RUST_KEYWORDS:
        return f"{rendered}_"
    return rendered


def _screaming(value: str) -> str:
    return _snake(value).upper()


def _field_identifier(wire_name: str) -> tuple[str, bool]:
    identifier = _snake(wire_name)
    return identifier, identifier != wire_name


def _string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _doc(text: str | None, indent: str = "") -> list[str]:
    if not text:
        return []
    words = " ".join(str(text).split()).replace("`", "\\`")
    return [f"{indent}/// {words}"]


def _serde_field_options(
    wire_name: str, field: Mapping[str, Any]
) -> list[str]:
    _, renamed = _field_identifier(wire_name)
    options: list[str] = []
    if renamed:
        options.append(f"rename = {_string(wire_name)}")
    for alias in field.get("aliases", ()):
        options.append(f"alias = {_string(str(alias))}")
    if field["presence"] == "optional":
        options.append("default")
        if field["nullable"]:
            options.append('skip_serializing_if = "Optional::is_missing"')
        else:
            options.append(
                'deserialize_with = "crate::presence::deserialize_optional_non_null"'
            )
            options.append('skip_serializing_if = "Option::is_none"')
    return options


def _header(ir: SdkIR) -> str:
    return (
        "// This file is generated. Do not edit by hand.\n"
        f"// cmux-tui mux protocol {ir.mux_protocol}, IR {ir.ir_sha256}.\n"
        "// The emitter owns this layout so generation is independent of the installed rustfmt.\n"
        "\n"
    )


class _Definitions:
    def __init__(self, *, ref_prefix: str) -> None:
        self.ref_prefix = ref_prefix
        self.definitions: dict[str, str] = {}
        self.in_progress: set[str] = set()

    def type_expr(
        self,
        expression: Mapping[str, Any],
        context: str,
        *,
        recursive_owner: str | None = None,
    ) -> str:
        kind = expression["kind"]
        if kind == "scalar":
            return _SCALARS[str(expression["name"])]
        if kind == "literal":
            value = expression["value"]
            if isinstance(value, bool):
                return "bool"
            if isinstance(value, str):
                return "String"
            if isinstance(value, int):
                return "i64" if value < 0 else "u64"
            if isinstance(value, float):
                return "f64"
            return "()"
        if kind == "enum":
            self.add_enum(context, expression)
            return context
        if kind == "object":
            self.add_object(context, expression, recursive_owner=recursive_owner)
            return context
        if kind == "alias":
            return self.type_expr(
                expression["target"],
                f"{context}Value",
                recursive_owner=recursive_owner,
            )
        if kind == "tagged_union":
            self.add_tagged_union(context, expression)
            return context
        if kind == "untagged_union":
            self.add_untagged_union(context, expression)
            return context
        if kind == "array":
            item = self.type_expr(
                expression["items"],
                f"{context}Item",
                recursive_owner=recursive_owner,
            )
            return f"Vec<{item}>"
        if kind == "map":
            value = self.type_expr(
                expression["values"],
                f"{context}Value",
                recursive_owner=recursive_owner,
            )
            return f"BTreeMap<String, {value}>"
        if kind == "ref":
            name = str(expression["name"])
            rendered = f"{self.ref_prefix}{name}"
            if recursive_owner == name:
                return f"Box<{rendered}>"
            return rendered
        if kind == "opaque_json":
            return "serde_json::Value"
        raise ValueError(f"unsupported Rust IR type kind: {kind}")

    def field_type(
        self,
        field: Mapping[str, Any],
        context: str,
        *,
        recursive_owner: str | None = None,
    ) -> str:
        rendered = self.type_expr(
            field["type"],
            context,
            recursive_owner=recursive_owner,
        )
        presence = field["presence"]
        nullable = bool(field["nullable"])
        if presence == "required" and nullable:
            return f"Nullable<{rendered}>"
        if presence == "optional" and nullable:
            return f"Optional<{rendered}>"
        if presence == "optional":
            return f"Option<{rendered}>"
        return rendered

    def add_enum(self, name: str, expression: Mapping[str, Any]) -> None:
        if name in self.definitions or name in self.in_progress:
            return
        self.in_progress.add(name)
        values = list(expression["values"])
        if not all(isinstance(value, str) for value in values):
            # The protocol currently uses string enums. Keep the renderer total
            # for future scalar enums without pretending a Rust discriminant has
            # JSON representation semantics.
            self.definitions[name] = (
                f"#[rustfmt::skip]\npub type {name} = serde_json::Value;\n"
            )
            self.in_progress.remove(name)
            return
        lines = [
            "#[rustfmt::skip]",
            "#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]",
            f"pub enum {name} {{",
        ]
        used: set[str] = set()
        for index, value in enumerate(values, start=1):
            variant = _pascal(value)
            if variant in used:
                variant = f"{variant}{index}"
            used.add(variant)
            lines.append(f"    #[serde(rename = {_string(value)})]")
            lines.append(f"    {variant},")
        lines.append("}")
        self.definitions[name] = "\n".join(lines) + "\n"
        self.in_progress.remove(name)

    def add_object(
        self,
        name: str,
        expression: Mapping[str, Any],
        *,
        recursive_owner: str | None = None,
        omitted_fields: frozenset[str] = frozenset(),
    ) -> None:
        if name in self.definitions or name in self.in_progress:
            return
        self.in_progress.add(name)
        fields = [
            (str(wire_name), field)
            for wire_name, field in expression["fields"].items()
            if wire_name not in omitted_fields
        ]
        all_optional = all(field["presence"] == "optional" for _, field in fields)
        derives = "Debug, Clone, PartialEq, Serialize, Deserialize"
        if all_optional:
            derives += ", Default"
        lines = ["#[rustfmt::skip]", f"#[derive({derives})]", f"pub struct {name} {{"]
        for wire_name, field in fields:
            field_name, _ = _field_identifier(wire_name)
            lines.extend(_doc(field.get("description"), "    "))
            serde_options = _serde_field_options(wire_name, field)
            if serde_options:
                lines.append(f"    #[serde({', '.join(serde_options)})]")
            field_context = f"{name}{_pascal(wire_name)}"
            rendered = self.field_type(
                field,
                field_context,
                recursive_owner=recursive_owner or name,
            )
            lines.append(f"    pub {field_name}: {rendered},")
        if expression.get("additional_properties"):
            lines.append("    #[serde(flatten)]")
            lines.append("    pub additional: BTreeMap<String, serde_json::Value>,")
        lines.append("}")
        self.definitions[name] = "\n".join(lines) + "\n"
        self.in_progress.remove(name)

    def add_tagged_union(self, name: str, expression: Mapping[str, Any]) -> None:
        if name in self.definitions or name in self.in_progress:
            return
        self.in_progress.add(name)
        tag = str(expression["tag"])
        lines = [
            "#[rustfmt::skip]",
            "#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]",
            f"#[serde(tag = {_string(tag)})]",
            f"pub enum {name} {{",
        ]
        used: set[str] = set()
        for index, (wire_variant, variant) in enumerate(
            expression["variants"].items(), start=1
        ):
            variant_name = _pascal(str(wire_variant))
            if variant_name in used:
                variant_name = f"{variant_name}{index}"
            used.add(variant_name)
            lines.append(f"    #[serde(rename = {_string(str(wire_variant))})]")
            if variant["kind"] == "object":
                payload_fields = [
                    (str(field_name), field)
                    for field_name, field in variant["fields"].items()
                    if field_name != tag
                ]
                if not payload_fields and not variant.get("additional_properties"):
                    lines.append(f"    {variant_name},")
                    continue
                lines.append(f"    {variant_name} {{")
                for field_name, field in payload_fields:
                    identifier, _ = _field_identifier(field_name)
                    serde_options = _serde_field_options(field_name, field)
                    if serde_options:
                        lines.append(f"        #[serde({', '.join(serde_options)})]")
                    rendered = self.field_type(
                        field,
                        f"{name}{variant_name}{_pascal(field_name)}",
                        recursive_owner=name,
                    )
                    lines.append(f"        {identifier}: {rendered},")
                if variant.get("additional_properties"):
                    lines.append("        #[serde(flatten)]")
                    lines.append(
                        "        additional: BTreeMap<String, serde_json::Value>,"
                    )
                lines.append("    },")
            else:
                rendered = self.type_expr(
                    variant,
                    f"{name}{variant_name}Value",
                    recursive_owner=name,
                )
                lines.append(f"    {variant_name}({rendered}),")
        lines.append("}")
        self.definitions[name] = "\n".join(lines) + "\n"
        self.in_progress.remove(name)

    def add_untagged_union(self, name: str, expression: Mapping[str, Any]) -> None:
        if name in self.definitions or name in self.in_progress:
            return
        self.in_progress.add(name)
        lines = [
            "#[rustfmt::skip]",
            "#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]",
            "#[serde(untagged)]",
            f"pub enum {name} {{",
        ]
        used: set[str] = set()
        for index, variant in enumerate(expression["variants"], start=1):
            if variant["kind"] == "ref":
                variant_name = _pascal(str(variant["name"]))
            else:
                variant_name = f"Variant{index}"
            if variant_name in used:
                variant_name = f"{variant_name}{index}"
            used.add(variant_name)
            rendered = self.type_expr(
                variant,
                f"{name}{variant_name}Value",
                recursive_owner=name,
            )
            lines.append(f"    {variant_name}({rendered}),")
        lines.append("}")
        self.definitions[name] = "\n".join(lines) + "\n"
        self.in_progress.remove(name)

    def render(self) -> str:
        # Inline definitions are discovered while earlier definitions render,
        # so insertion order gives a deterministic, readable dependency order.
        return "\n".join(self.definitions.values()).rstrip() + "\n"


def _render_types(ir: SdkIR, document: Mapping[str, Any]) -> str:
    definitions = _Definitions(ref_prefix="")
    aliases: list[str] = []
    for name, expression in document["types"].items():
        kind = expression["kind"]
        if kind in {"object", "enum", "tagged_union", "untagged_union"}:
            definitions.type_expr(expression, str(name), recursive_owner=str(name))
        elif kind == "opaque_json":
            aliases.append(f"#[rustfmt::skip]\npub type {name} = serde_json::Value;")
        else:
            rendered = definitions.type_expr(
                expression,
                f"{name}Value",
                recursive_owner=str(name),
            )
            aliases.append(f"#[rustfmt::skip]\npub type {name} = {rendered};")
    body = definitions.render()
    return (
        _header(ir)
        + "use crate::{Nullable, Optional};\n"
        + "use serde::{Deserialize, Serialize};\n"
        + "use std::collections::BTreeMap;\n\n"
        + "\n".join(aliases)
        + ("\n\n" if aliases else "")
        + body
    )


def _render_commands(ir: SdkIR, document: Mapping[str, Any]) -> str:
    definitions = _Definitions(ref_prefix="T::")
    request_names: dict[str, str] = {}
    result_names: dict[str, str] = {}
    for wire_name, command in document["commands"].items():
        stem = _pascal(str(wire_name))
        request_name = f"{stem}Request"
        result_name = f"{stem}Result"
        request_names[str(wire_name)] = request_name
        definitions.type_expr(command["request"], request_name)
        result = command["result"]
        rendered = definitions.type_expr(result, result_name)
        if result["kind"] == "ref" and result["name"] == result_name:
            result_names[str(wire_name)] = f"T::{result_name}"
        else:
            result_names[str(wire_name)] = result_name
        if rendered != result_name and result_names[str(wire_name)] == result_name:
            definitions.definitions[result_name] = (
                f"#[rustfmt::skip]\npub type {result_name} = {rendered};\n"
            )

    lines = [
        _header(ir).rstrip(),
        "",
        "use super::metadata::*;",
        "use super::types as T;",
        "use crate::{CmuxClient, CmuxStream, Nullable, Optional, Result};",
        "use serde::{Deserialize, Serialize};",
        "use std::collections::BTreeMap;",
        "",
        definitions.render().rstrip(),
        "",
        "#[rustfmt::skip]",
        "impl CmuxClient {",
    ]
    for wire_name, command in document["commands"].items():
        wire_name = str(wire_name)
        method = _snake(wire_name)
        request_name = request_names[wire_name]
        metadata_name = f"{_screaming(wire_name)}_METADATA"
        guards: list[str] = []
        for field_name, field in command["request"]["fields"].items():
            since = field.get("since")
            capability = field.get("capability")
            if since is None and capability is None:
                continue
            identifier, _ = _field_identifier(str(field_name))
            checks: list[str] = []
            if since is not None:
                checks.append(
                    f'self.require_protocol_field("{wire_name}", {int(since)})?;'
                )
            if capability is not None:
                checks.append(
                    "self.require_capability_field("
                    f'"{wire_name}", {_string(str(capability))}'
                    ")?;"
                )
            if field["presence"] == "required":
                guards.extend(f"        {check}" for check in checks)
            else:
                present = (
                    f"!request.{identifier}.is_missing()"
                    if field["nullable"]
                    else f"request.{identifier}.is_some()"
                )
                guards.append(f"        if {present} {{")
                guards.extend(f"            {check}" for check in checks)
                guards.append("        }")
        if wire_name == "identify":
            result_name = result_names[wire_name]
            lines.extend(
                [
                    f"    pub fn {method}(&mut self, request: {request_name}) -> Result<{result_name}> {{",
                    *guards,
                    f"        self.execute_identify(&{metadata_name}, &request)",
                    "    }",
                ]
            )
        elif command["stream"] is not None:
            lines.extend(
                [
                    f"    pub fn {method}(&mut self, request: {request_name}) -> Result<CmuxStream> {{",
                    *guards,
                    f"        self.execute_stream(&{metadata_name}, &request)",
                    "    }",
                ]
            )
        else:
            result_name = result_names[wire_name]
            lines.extend(
                [
                    f"    pub fn {method}(&mut self, request: {request_name}) -> Result<{result_name}> {{",
                    *guards,
                    f"        self.execute(&{metadata_name}, &request)",
                    "    }",
                ]
            )
        lines.append("")
    lines.append("}")
    return "\n".join(lines).rstrip() + "\n"


def _render_events(ir: SdkIR, document: Mapping[str, Any]) -> str:
    definitions = _Definitions(ref_prefix="T::")
    event_types: dict[str, str] = {}
    variants: dict[str, str] = {}
    used_variants: set[str] = set()
    for index, (wire_name, event) in enumerate(document["events"].items(), start=1):
        wire_name = str(wire_name)
        stem = _pascal(wire_name)
        event_type = f"{stem}Event"
        event_types[wire_name] = event_type
        definitions.add_object(
            event_type,
            event["payload"],
            omitted_fields=frozenset({"event"}),
        )
        variant = stem
        if variant in used_variants:
            variant = f"{variant}{index}"
        used_variants.add(variant)
        variants[wire_name] = variant

    lines = [
        _header(ir).rstrip(),
        "",
        "use super::metadata::*;",
        "use super::types as T;",
        "use crate::{EventMetadata, Nullable, Optional};",
        "use serde::{Deserialize, Serialize};",
        "use serde_json::Value;",
        "use std::collections::BTreeMap;",
        "",
        definitions.render().rstrip(),
        "",
        "#[rustfmt::skip]",
        "#[derive(Debug, Clone, PartialEq)]",
        "pub struct UnknownEvent {",
        "    pub name: Option<String>,",
        "    pub raw: Value,",
        "    pub decode_error: Option<String>,",
        "}",
        "",
        "#[rustfmt::skip]",
        "#[non_exhaustive]",
        "#[derive(Debug, Clone, PartialEq)]",
        "pub enum Event {",
    ]
    for wire_name in document["events"]:
        wire_name = str(wire_name)
        lines.append(f"    {variants[wire_name]}({event_types[wire_name]}),")
    lines.extend(
        ["    Unknown(UnknownEvent),", "}", "", "#[rustfmt::skip]", "impl Event {"]
    )
    lines.append("    pub fn wire_name(&self) -> Option<&str> {")
    lines.append("        match self {")
    for wire_name in document["events"]:
        wire_name = str(wire_name)
        lines.append(f'            Self::{variants[wire_name]}(_) => Some("{wire_name}"),')
    lines.append("            Self::Unknown(event) => event.name.as_deref(),")
    lines.extend(["        }", "    }", ""])
    lines.append("    pub fn metadata(&self) -> Option<&'static EventMetadata> {")
    lines.append("        match self {")
    for wire_name in document["events"]:
        wire_name = str(wire_name)
        lines.append(
            f"            Self::{variants[wire_name]}(_) => Some(&{_screaming(wire_name)}_EVENT_METADATA),"
        )
    lines.append("            Self::Unknown(_) => None,")
    lines.extend(["        }", "    }", "}", ""])
    lines.extend(
        [
            "#[rustfmt::skip]",
            "pub fn decode_event(raw: Value) -> Event {",
            '    let name = raw.get("event").and_then(Value::as_str).map(str::to_owned);',
            "    match name.as_deref() {",
        ]
    )
    for wire_name in document["events"]:
        wire_name = str(wire_name)
        event_type = event_types[wire_name]
        variant = variants[wire_name]
        lines.extend(
            [
                f'        Some("{wire_name}") => match serde_json::from_value::<{event_type}>(raw.clone()) {{',
                f"            Ok(event) => Event::{variant}(event),",
                "            Err(error) => Event::Unknown(UnknownEvent {",
                "                name,",
                "                raw,",
                "                decode_error: Some(error.to_string()),",
                "            }),",
                "        },",
            ]
        )
    lines.extend(
        [
            "        _ => Event::Unknown(UnknownEvent {",
            "            name,",
            "            raw,",
            "            decode_error: None,",
            "        }),",
            "    }",
            "}",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def _option_string(value: Any) -> str:
    return "None" if value is None else f"Some({_string(str(value))})"


def _render_metadata(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = [
        _header(ir).rstrip(),
        "",
        "use crate::{CommandMetadata, EventMetadata, ProfileMetadata, StreamMetadata};",
        "",
        f"pub const SDK_SCHEMA_VERSION: u32 = {ir.schema_version};",
        f"pub const MUX_PROTOCOL_VERSION: u32 = {ir.mux_protocol};",
        f'pub const SDK_IR_SHA256: &str = "{ir.ir_sha256}";',
        "",
    ]
    profile_constants: list[str] = []
    for name, profile in document["profiles"].items():
        constant = f"{_screaming(str(name))}_PROFILE"
        profile_constants.append(constant)
        inherits = ", ".join(_string(str(item)) for item in profile["inherits"])
        lines.extend(
            [
                "#[rustfmt::skip]",
                f"pub const {constant}: ProfileMetadata = ProfileMetadata {{",
                f"    name: {_string(str(name))},",
                f"    description: {_string(str(profile['description']))},",
                f"    inherits: &[{inherits}],",
                f"    transport: {_option_string(profile.get('transport'))},",
                f"    requires_authority: {str(bool(profile.get('requires_authority', False))).lower()},",
                "};",
                "",
            ]
        )
    command_constants: list[str] = []
    for wire_name, command in document["commands"].items():
        wire_name = str(wire_name)
        constant = f"{_screaming(wire_name)}_METADATA"
        command_constants.append(constant)
        stream = command["stream"]
        if stream is None:
            stream_value = "None"
        else:
            stream_value = (
                "Some(StreamMetadata { "
                f"kind: {_string(str(stream['kind']))}, "
                f"terminal_event: {_option_string(stream.get('terminal_event'))} "
                "})"
            )
        lines.extend(
            [
                "#[rustfmt::skip]",
                f"pub const {constant}: CommandMetadata = CommandMetadata {{",
                f"    name: {_string(wire_name)},",
                f"    since: {int(command['since'])},",
                f"    capability: {_option_string(command.get('capability'))},",
                f"    authority: {_string(str(command['authority']))},",
                f"    stream: {stream_value},",
                "};",
                "",
            ]
        )
    event_constants: list[str] = []
    for wire_name, event in document["events"].items():
        wire_name = str(wire_name)
        constant = f"{_screaming(wire_name)}_EVENT_METADATA"
        event_constants.append(constant)
        streams = ", ".join(_string(str(item)) for item in event["streams"])
        lines.extend(
            [
                "#[rustfmt::skip]",
                f"pub const {constant}: EventMetadata = EventMetadata {{",
                f"    name: {_string(wire_name)},",
                f"    since: {int(event['since'])},",
                f"    capability: {_option_string(event.get('capability'))},",
                f"    streams: &[{streams}],",
                f"    emission: {_string(str(event['emission']))},",
                "};",
                "",
            ]
        )
    lines.extend(
        [
            "#[rustfmt::skip]",
            "pub static PROFILES: &[ProfileMetadata] = &["
            + ", ".join(profile_constants)
            + "];",
        ]
    )
    lines.extend(
        [
            "#[rustfmt::skip]",
            "pub static COMMANDS: &[CommandMetadata] = &["
            + ", ".join(command_constants)
            + "];",
        ]
    )
    lines.extend(
        [
            "#[rustfmt::skip]",
            "pub static EVENTS: &[EventMetadata] = &["
            + ", ".join(event_constants)
            + "];",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def _render_mod(ir: SdkIR) -> str:
    return (
        _header(ir)
        + "mod commands;\n"
        + "mod events;\n"
        + "mod metadata;\n"
        + "mod types;\n\n"
        + "pub use commands::*;\n"
        + "pub use events::*;\n"
        + "pub use metadata::*;\n"
        + "pub use types::*;\n"
    )


def emit(ir: SdkIR) -> Mapping[str | PurePosixPath, str | bytes]:
    document = _plain(ir.document)
    return {
        "mod.rs": _render_mod(ir),
        "types.rs": _render_types(ir, document),
        "commands.rs": _render_commands(ir, document),
        "events.rs": _render_events(ir, document),
        "metadata.rs": _render_metadata(ir, document),
    }


EMITTER = Emitter(
    language="rust",
    output_root=PurePosixPath("rust/src/generated"),
    render=emit,
)
