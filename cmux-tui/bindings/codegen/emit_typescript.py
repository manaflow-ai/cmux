from __future__ import annotations

import json
import re
from pathlib import PurePosixPath
from typing import Any, Mapping

try:
    from . import ir as ir_module
    from . import writer
except ImportError:  # pragma: no cover - supports direct emitter imports in tooling.
    import ir as ir_module  # type: ignore[no-redef]
    import writer  # type: ignore[no-redef]


_SCALARS = {
    "string": "string",
    "boolean": "boolean",
    "int32": "number",
    "uint16": "number",
    "uint32": "number",
    "float32": "number",
    "float64": "number",
    "int64": "bigint",
    "uint64": "bigint",
}


def _plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    return value


def _pascal(wire_name: str) -> str:
    parts = [part for part in re.split(r"[^A-Za-z0-9]+", wire_name) if part]
    return "".join(part[:1].upper() + part[1:] for part in parts)


def _literal(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return json.dumps(value, ensure_ascii=False)


def _property(name: str) -> str:
    return json.dumps(name, ensure_ascii=False)


def _comment(description: str | None, indent: str = "") -> list[str]:
    if not description:
        return []
    safe = " ".join(str(description).replace("*/", "* /").split())
    return [f"{indent}/** {safe} */"]


def _type_expr(expr: Mapping[str, Any], ref_prefix: str = "") -> str:
    kind = expr["kind"]
    if kind == "scalar":
        return _SCALARS[expr["name"]]
    if kind == "literal":
        return _literal(expr["value"])
    if kind == "enum":
        return " | ".join(_literal(value) for value in expr["values"])
    if kind == "object":
        return _object_expr(expr, ref_prefix)
    if kind == "alias":
        return _type_expr(expr["target"], ref_prefix)
    if kind == "tagged_union":
        tag = _property(expr["tag"])
        variants = []
        for value, variant in expr["variants"].items():
            payload = _type_expr(variant, ref_prefix)
            variants.append(f"({{ {tag}: {_literal(value)} }} & {payload})")
        return " | ".join(variants)
    if kind == "untagged_union":
        return " | ".join(
            f"({_type_expr(variant, ref_prefix)})" for variant in expr["variants"]
        )
    if kind == "array":
        return f"Array<{_type_expr(expr['items'], ref_prefix)}>"
    if kind == "map":
        return f"Record<string, {_type_expr(expr['values'], ref_prefix)}>"
    if kind == "ref":
        return f"{ref_prefix}{expr['name']}"
    if kind == "opaque_json":
        return f"{ref_prefix}JsonValue"
    raise ValueError(f"unsupported TypeScript IR type kind: {kind}")


def _object_expr(expr: Mapping[str, Any], ref_prefix: str = "") -> str:
    lines = ["{"]
    lines.extend(_field_lines(expr, ref_prefix))
    lines.append("}")
    return "\n".join(lines)


def _field_lines(expr: Mapping[str, Any], ref_prefix: str = "") -> list[str]:
    lines: list[str] = []
    for name, field in expr["fields"].items():
        lines.extend(_comment(field.get("description"), "  "))
        optional = "?" if field["presence"] == "optional" else ""
        rendered = _type_expr(field["type"], ref_prefix)
        if field["nullable"]:
            rendered = f"({rendered}) | null"
        lines.append(f"  {_property(name)}{optional}: {rendered};")
    if expr["additional_properties"]:
        lines.append(f"  [key: string]: {ref_prefix}JsonValue;")
    return lines


def _header(ir: Any) -> str:
    return (
        "/* This file is generated. Do not edit by hand. */\n"
        f"/* cmux-tui mux protocol {ir.mux_protocol}, IR {ir.ir_sha256}. */\n\n"
    )


def _render_types(ir: Any, document: Mapping[str, Any]) -> str:
    lines = [_header(ir)]
    lines.append(
        "/** JSON accepted by the wire codec. bigint is serialized as an exact JSON integer. */"
    )
    lines.append(
        "export type JsonValue = null | boolean | number | bigint | string | "
        "JsonValue[] | { [key: string]: JsonValue };"
    )
    lines.append("export type JsonObject = { [key: string]: JsonValue };")
    lines.append("")
    for name, expr in document["types"].items():
        if name in {"JsonValue", "JsonObject"}:
            continue
        if expr["kind"] == "opaque_json":
            lines.append(
                f"/** Opaque JSON: {str(expr['reason']).replace('*/', '* /')} */"
            )
        lines.append(f"export type {name} = {_type_expr(expr)};")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _render_commands(ir: Any, document: Mapping[str, Any]) -> str:
    commands = document["commands"]
    named_types = set(document["types"])
    lines = [_header(ir), 'import type * as T from "./types.js";', ""]
    lines.extend(
        [
            "export interface CmuxRequestBase {",
            "  id?: T.JsonValue;",
            "  cmd: string;",
            "}",
            "",
            "export interface CmuxSuccessResponse<D = T.JsonValue> {",
            "  id?: T.JsonValue;",
            "  ok: true;",
            "  data: D;",
            "}",
            "export interface CmuxFailureResponse {",
            "  id?: T.JsonValue;",
            "  ok: false;",
            "  error: string;",
            "}",
            "export type CmuxResponse<D = T.JsonValue> =",
            "  | CmuxSuccessResponse<D>",
            "  | CmuxFailureResponse;",
            "",
        ]
    )

    request_names: dict[str, str] = {}
    result_names: dict[str, str] = {}
    for wire_name, command in commands.items():
        stem = _pascal(wire_name)
        request_name = f"{stem}Request"
        result_name = f"{stem}Result"
        request_names[wire_name] = request_name
        result_names[wire_name] = result_name

        request = command["request"]
        fields = dict(request["fields"])
        fields.pop("cmd", None)
        fields.pop("id", None)
        lines.extend(_comment(f"Protocol v{command['since']}; authority: {command['authority']}."))
        lines.append(f"export interface {request_name} extends CmuxRequestBase {{")
        lines.append(f"  cmd: {_literal(wire_name)};")
        request_payload = {**request, "fields": fields}
        lines.extend(_field_lines(request_payload, "T."))
        lines.append("}")
        if result_name not in named_types:
            lines.append(
                f"export type {result_name} = {_type_expr(command['result'], 'T.')};"
            )
        lines.append("")

    lines.append("/** Every implemented protocol command request. */")
    lines.append("export type CmuxRequest =")
    for index, wire_name in enumerate(commands):
        suffix = ";" if index == len(commands) - 1 else ""
        lines.append(f"  | {request_names[wire_name]}{suffix}")
    lines.append("")
    lines.append("/** Command name to request, result, authority, and version mapping. */")
    lines.append("export interface CmuxCommandDefinitionMap {")
    for wire_name, command in commands.items():
        result = result_names[wire_name]
        if result in named_types:
            result = f"T.{result}"
        capability = _literal(command["capability"])
        stream_kind = (
            _literal(command["stream"]["kind"]) if command["stream"] is not None else "null"
        )
        lines.append(f"  {_property(wire_name)}: {{")
        lines.append(f"    request: {request_names[wire_name]};")
        lines.append(f"    result: {result};")
        lines.append(f"    authority: {_literal(command['authority'])};")
        lines.append(f"    since: {command['since']};")
        lines.append(f"    capability: {capability};")
        lines.append(f"    stream: {stream_kind};")
        lines.append("  };")
    lines.append("}")
    lines.extend(
        [
            "",
            "export type CmuxCommand = keyof CmuxCommandDefinitionMap;",
            "export type CmuxRequestFor<C extends CmuxCommand> =",
            '  CmuxCommandDefinitionMap[C]["request"];',
            "type DistributiveOmit<V, K extends PropertyKey> =",
            "  V extends unknown ? Omit<V, Extract<keyof V, K>> : never;",
            "export type CmuxRequestParams<C extends CmuxCommand> =",
            '  DistributiveOmit<CmuxRequestFor<C>, "id" | "cmd">;',
            "export type CmuxResponseDataFor<C extends CmuxCommand> =",
            '  CmuxCommandDefinitionMap[C]["result"];',
            "export type CmuxResponseData<R extends CmuxRequest> =",
            "  CmuxResponseDataFor<R[\"cmd\"]>;",
            "export type CmuxAuthorityFor<C extends CmuxCommand> =",
            '  CmuxCommandDefinitionMap[C]["authority"];',
            "export type CmuxSinceFor<C extends CmuxCommand> =",
            '  CmuxCommandDefinitionMap[C]["since"];',
            "",
            "/** Canonical typed call surface. Convenience methods are handwritten. */",
            "export interface CmuxCommandCaller {",
            "  request<R extends CmuxRequest>(request: R): Promise<CmuxResponseData<R>>;",
            "  request<C extends CmuxCommand>(",
            "    command: C,",
            "    ...args: Record<string, never> extends CmuxRequestParams<C>",
            "      ? [params?: CmuxRequestParams<C>]",
            "      : [params: CmuxRequestParams<C>]",
            "  ): Promise<CmuxResponseDataFor<C>>;",
            "}",
            "",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def _event_type_name(wire_name: str) -> str:
    return f"{_pascal(wire_name)}Event"


def _union(lines: list[str], name: str, members: list[str], doc: str) -> None:
    lines.append(f"/** {doc} */")
    if not members:
        lines.append(f"export type {name} = never;")
    else:
        lines.append(f"export type {name} =")
        for index, member in enumerate(members):
            suffix = ";" if index == len(members) - 1 else ""
            lines.append(f"  | {member}{suffix}")
    lines.append("")


def _render_events(ir: Any, document: Mapping[str, Any]) -> str:
    events = document["events"]
    lines = [_header(ir), 'import type * as T from "./types.js";', ""]
    event_names: dict[str, str] = {}
    for wire_name, event in events.items():
        type_name = _event_type_name(wire_name)
        event_names[wire_name] = type_name
        payload = event["payload"]
        fields = dict(payload["fields"])
        fields.pop("event", None)
        payload = {**payload, "fields": fields}
        lines.extend(
            _comment(
                f"Protocol v{event['since']}; emission: {event['emission']}; "
                f"streams: {', '.join(event['streams']) or 'none'}."
            )
        )
        lines.append(
            f"export type {type_name} = {{ event: {_literal(wire_name)} }} & "
            f"{_type_expr(payload, 'T.')};"
        )
        lines.append("")

    emitted = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted"
    ]
    serialized_only = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] != "emitted"
    ]
    subscribe = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted"
        and any(stream.startswith("subscribe") for stream in event["streams"])
    ]
    subscribe_deltas = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted" and "subscribe-deltas" in event["streams"]
    ]
    attach = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted"
        and any(stream.startswith("attach-") for stream in event["streams"])
    ]
    attach_byte = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted" and "attach-byte" in event["streams"]
    ]
    attach_render = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted" and "attach-render" in event["streams"]
    ]
    attach_browser = [
        event_names[name]
        for name, event in events.items()
        if event["emission"] == "emitted" and "attach-browser" in event["streams"]
    ]
    lines.extend(
        [
            "/** A forward-compatible event not known to this SDK version. */",
            "export interface UnknownEvent {",
            "  event: string;",
            "  [key: string]: unknown;",
            "}",
            "",
        ]
    )
    _union(
        lines,
        "KnownCmuxEvent",
        emitted,
        f"Every event emitted by protocol v{ir.mux_protocol}.",
    )
    _union(
        lines,
        "SerializedButNotEmittedEvent",
        serialized_only,
        "Shapes serialized by runtime code but excluded from active event unions.",
    )
    _union(lines, "KnownSubscribeEvent", subscribe, "Known subscribe stream events.")
    _union(lines, "TreeDeltaEvent", subscribe_deltas, "Known delta-subscription events.")
    _union(lines, "KnownAttachEvent", attach, "Known events from any attach mode.")
    _union(lines, "KnownByteAttachEvent", attach_byte, "Known byte attach events.")
    _union(lines, "KnownRenderAttachEvent", attach_render, "Known render attach events.")
    _union(lines, "KnownBrowserAttachEvent", attach_browser, "Known browser attach events.")
    lines.extend(
        [
            "export type CmuxEvent = KnownCmuxEvent | UnknownEvent;",
            "export type SubscribeEvent = KnownSubscribeEvent | UnknownEvent;",
            "export type AttachEvent = KnownAttachEvent | UnknownEvent;",
            "export type ByteAttachEvent = KnownByteAttachEvent | UnknownEvent;",
            "export type RenderAttachEvent = KnownRenderAttachEvent | UnknownEvent;",
            "export type BrowserAttachEvent = KnownBrowserAttachEvent | UnknownEvent;",
            "",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def _render_metadata(ir: Any, document: Mapping[str, Any]) -> str:
    protocol = document["protocol"]
    commands = document["commands"]
    events = document["events"]
    command_metadata = {
        name: {
            "authority": value["authority"],
            "since": value["since"],
            "capability": value["capability"],
            "fields": {
                field_name: {
                    "since": field.get("since"),
                    "capability": field.get("capability"),
                }
                for field_name, field in value["request"]["fields"].items()
                if field.get("since") is not None
                or field.get("capability") is not None
            },
            "stream": value["stream"],
            "constraints": value["constraints"],
        }
        for name, value in commands.items()
    }
    event_metadata = {
        name: {
            "since": value["since"],
            "capability": value["capability"],
            "streams": value["streams"],
            "emission": value["emission"],
        }
        for name, value in events.items()
    }
    command_schemas = {
        name: {"request": value["request"], "result": value["result"]}
        for name, value in commands.items()
    }
    event_schemas = {name: value["payload"] for name, value in events.items()}
    lines = [
        _header(ir),
        f"export const SDK_SCHEMA_VERSION = {ir.schema_version} as const;",
        f"export const MUX_PROTOCOL_VERSION = {ir.mux_protocol} as const;",
        f"export const SDK_IR_SHA256 = {_literal(ir.ir_sha256)} as const;",
        f"export const PROTOCOL = {json.dumps(_plain(protocol), ensure_ascii=False, indent=2)} as const;",
        f"export const PROFILES = {json.dumps(_plain(document['profiles']), ensure_ascii=False, indent=2)} as const;",
        f"export const COMMAND_METADATA = {json.dumps(command_metadata, ensure_ascii=False, indent=2)} as const;",
        f"export const EVENT_METADATA = {json.dumps(event_metadata, ensure_ascii=False, indent=2)} as const;",
        "export type TypeSchema = Readonly<Record<string, unknown>>;",
        "export interface CommandSchema {",
        "  readonly request: TypeSchema;",
        "  readonly result: TypeSchema;",
        "}",
        f"export const TYPE_SCHEMAS: Readonly<Record<string, TypeSchema>> = {json.dumps(_plain(document['types']), ensure_ascii=False, indent=2)};",
        f"export const COMMAND_SCHEMAS: Readonly<Record<string, CommandSchema>> = {json.dumps(command_schemas, ensure_ascii=False, indent=2)};",
        f"export const EVENT_SCHEMAS: Readonly<Record<string, TypeSchema>> = {json.dumps(event_schemas, ensure_ascii=False, indent=2)};",
        "",
        "export type CmuxAuthority = typeof COMMAND_METADATA[keyof typeof COMMAND_METADATA][\"authority\"];",
        "export type CmuxProfile = keyof typeof PROFILES;",
        "export type EmittedEventName = {",
        "  [E in keyof typeof EVENT_METADATA]:",
        '    typeof EVENT_METADATA[E]["emission"] extends "emitted" ? E : never;',
        "}[keyof typeof EVENT_METADATA];",
        "",
    ]
    return "\n".join(lines).rstrip() + "\n"


def _render_index(ir: Any) -> str:
    return (
        _header(ir)
        + 'export * from "./types.js";\n'
        + 'export * from "./commands.js";\n'
        + 'export * from "./events.js";\n'
        + 'export * from "./metadata.js";\n'
    )


def emit(ir: ir_module.SdkIR) -> Mapping[str | PurePosixPath, str | bytes]:
    document = _plain(ir.document)
    return {
        "types.ts": _render_types(ir, document),
        "commands.ts": _render_commands(ir, document),
        "events.ts": _render_events(ir, document),
        "metadata.ts": _render_metadata(ir, document),
        "index.ts": _render_index(ir),
    }


EMITTER = writer.Emitter(
    language="typescript",
    output_root=PurePosixPath("typescript/src/raw/generated"),
    render=emit,
)
