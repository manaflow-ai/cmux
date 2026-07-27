"""Deterministic, standard-library-only Go SDK wire layer."""

from __future__ import annotations

import json
import subprocess
from collections.abc import Mapping
from pathlib import PurePosixPath
from typing import Any

from codegen.ir import SdkIR
from codegen.naming import words
from codegen.writer import Emitter


_SCALARS = {
    "string": "string",
    "boolean": "bool",
    "int32": "int32",
    "uint16": "uint16",
    "uint32": "uint32",
    "int64": "int64",
    "uint64": "uint64",
    "float32": "float32",
    "float64": "float64",
}

_ACRONYMS = {
    "api": "API",
    "cdp": "CDP",
    "css": "CSS",
    "id": "ID",
    "ids": "IDs",
    "io": "IO",
    "ip": "IP",
    "json": "JSON",
    "osc": "OSC",
    "pid": "PID",
    "pty": "PTY",
    "rgb": "RGB",
    "sdk": "SDK",
    "ssh": "SSH",
    "tui": "TUI",
    "uri": "URI",
    "url": "URL",
    "utf8": "UTF8",
    "vt": "VT",
    "ws": "WS",
}

_SPECIAL_METHODS = {"send", "subscribe", "attach-surface"}

_ARGUMENT_ORDER = {
    "surface": 0,
    "pane": 1,
    "screen": 2,
    "workspace": 3,
    "split": 4,
    "client": 5,
    "terminal_id": 6,
    "workspace_key": 7,
    "request": 8,
    "dir": 20,
    "index": 21,
    "name": 22,
    "title": 23,
    "body": 24,
    "url": 25,
    "text": 26,
    "pattern": 27,
    "start": 28,
    "count": 29,
    "cols": 30,
    "rows": 31,
    "width_px": 32,
    "height_px": 33,
    "ratio": 34,
    "delta": 35,
    "timeout_ms": 36,
    "approve": 37,
}


def _plain(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_plain(item) for item in value]
    return value


def _go_name(value: str) -> str:
    rendered = "".join(
        _ACRONYMS.get(word, word[:1].upper() + word[1:]) for word in words(value)
    )
    if not rendered:
        return "Value"
    if rendered[0].isdigit():
        return "N" + rendered
    return rendered


def _go_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _go_map(values: Mapping[str, Any], value_type: str) -> str:
    if not values:
        return "nil"
    entries = ", ".join(
        f"{_go_string(str(name))}: {_go_string(value) if isinstance(value, str) else value}"
        for name, value in values.items()
    )
    return f"map[string]{value_type}{{{entries}}}"


def _underlying_literal_type(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int64"
    if isinstance(value, float):
        return "float64"
    if isinstance(value, str):
        return "string"
    return "any"


def _enum_base(values: list[Any]) -> str:
    rendered = {_underlying_literal_type(value) for value in values}
    return rendered.pop() if len(rendered) == 1 else "any"


def _go_type(expr: Mapping[str, Any], *, anonymous_indent: str = "") -> str:
    kind = expr["kind"]
    if kind == "scalar":
        return _SCALARS[expr["name"]]
    if kind == "literal":
        return _underlying_literal_type(expr["value"])
    if kind == "enum":
        return _enum_base(list(expr["values"]))
    if kind == "object":
        return _anonymous_struct(expr, anonymous_indent)
    if kind == "alias":
        return _go_type(expr["target"], anonymous_indent=anonymous_indent)
    if kind in {"tagged_union", "untagged_union"}:
        return "json.RawMessage"
    if kind == "array":
        return "[]" + _go_type(expr["items"], anonymous_indent=anonymous_indent)
    if kind == "map":
        return "map[string]" + _go_type(
            expr["values"], anonymous_indent=anonymous_indent
        )
    if kind == "ref":
        return _go_name(expr["name"])
    if kind == "opaque_json":
        return "json.RawMessage"
    raise ValueError(f"unsupported Go IR type kind: {kind}")


def _field_type(field: Mapping[str, Any], *, indent: str = "") -> str:
    rendered = _go_type(field["type"], anonymous_indent=indent)
    if field["presence"] == "optional" or field["nullable"]:
        rendered = "*" + rendered
    return rendered


def _field_tag(wire_name: str, field: Mapping[str, Any]) -> str:
    suffix = ",omitempty" if field["presence"] == "optional" else ""
    return f'`json:"{wire_name}{suffix}"`'


def _anonymous_struct(expr: Mapping[str, Any], indent: str) -> str:
    if not expr["fields"] and not expr["additional_properties"]:
        return "struct{}"
    lines = ["struct {"]
    for wire_name, field in expr["fields"].items():
        lines.append(
            f"{indent}\t{_go_name(wire_name)} "
            f"{_field_type(field, indent=indent + chr(9))} "
            f"{_field_tag(wire_name, field)}"
        )
    if expr["additional_properties"]:
        lines.append(
            f'{indent}\tAdditional map[string]json.RawMessage `json:"-"`'
        )
    lines.append(indent + "}")
    return "\n".join(lines)


def _doc(description: Any, indent: str) -> list[str]:
    if not description:
        return []
    text = " ".join(str(description).split())
    return [f"{indent}// {text}"]


def _render_object(name: str, expr: Mapping[str, Any]) -> list[str]:
    lines = [f"type {name} struct {{"]
    for wire_name, field in expr["fields"].items():
        lines.extend(_doc(field.get("description"), "\t"))
        lines.append(
            f"\t{_go_name(wire_name)} {_field_type(field, indent=chr(9))} "
            f"{_field_tag(wire_name, field)}"
        )
    if expr["additional_properties"]:
        lines.append('\tAdditional map[string]json.RawMessage `json:"-"`')
    lines.append("}")
    return lines


def _variant_name(union_name: str, tag_value: str) -> str:
    return union_name + _go_name(tag_value)


def _render_tagged_union(name: str, expr: Mapping[str, Any]) -> list[str]:
    tag = expr["tag"]
    lines: list[str] = []
    for tag_value, variant in expr["variants"].items():
        variant_name = _variant_name(name, str(tag_value))
        if variant["kind"] == "object":
            lines.extend(_render_object(variant_name, variant))
        else:
            lines.append(f"type {variant_name} = {_go_type(variant)}")
        lines.append("")
    lines.extend(
        [
            f"type {name} struct {{",
            f'\tTag string `json:"{tag}"`',
            "\tValue any `json:\"-\"`",
            "\tRaw json.RawMessage `json:\"-\"`",
            "}",
            "",
            f"func (value *{name}) UnmarshalJSON(data []byte) error {{",
            f'\tvar tag struct {{ Tag string `json:"{tag}"` }}',
            "\tif err := decodeJSON(data, &tag); err != nil {",
            "\t\treturn err",
            "\t}",
            "\tvalue.Tag = tag.Tag",
            "\tvalue.Raw = append(value.Raw[:0], data...)",
            "\tswitch tag.Tag {",
        ]
    )
    for tag_value, _variant in expr["variants"].items():
        variant_name = _variant_name(name, str(tag_value))
        lines.extend(
            [
                f"\tcase {_go_string(str(tag_value))}:",
                f"\t\tvar decoded {variant_name}",
                "\t\tif err := decodeJSON(data, &decoded); err != nil {",
                "\t\t\treturn err",
                "\t\t}",
                "\t\tvalue.Value = decoded",
            ]
        )
    lines.extend(
        [
            "\tdefault:",
            "\t\tvalue.Value = nil",
            "\t}",
            "\treturn nil",
            "}",
            "",
            f"func (value {name}) MarshalJSON() ([]byte, error) {{",
            "\tif value.Value == nil {",
            "\t\tif value.Raw != nil {",
            "\t\t\treturn value.Raw, nil",
            "\t\t}",
            f'\t\treturn json.Marshal(map[string]any{{{_go_string(tag)}: value.Tag}})',
            "\t}",
            "\tpayload, err := json.Marshal(value.Value)",
            "\tif err != nil {",
            "\t\treturn nil, err",
            "\t}",
            "\tvar fields map[string]json.RawMessage",
            "\tif err := decodeJSON(payload, &fields); err != nil {",
            "\t\treturn nil, err",
            "\t}",
            "\tencodedTag, err := json.Marshal(value.Tag)",
            "\tif err != nil {",
            "\t\treturn nil, err",
            "\t}",
            f"\tfields[{_go_string(tag)}] = encodedTag",
            "\treturn json.Marshal(fields)",
            "}",
        ]
    )
    for tag_value, _variant in expr["variants"].items():
        variant_name = _variant_name(name, str(tag_value))
        accessor = _go_name(str(tag_value))
        lines.extend(
            [
                "",
                f"func New{name}{accessor}(value {variant_name}) {name} {{",
                f"\treturn {name}{{Tag: {_go_string(str(tag_value))}, Value: value}}",
                "}",
                "",
                f"func (value {name}) As{accessor}() ({variant_name}, bool) {{",
                f"\tdecoded, ok := value.Value.({variant_name})",
                "\treturn decoded, ok",
                "}",
            ]
        )
    return lines


def _resolved_expr(
    expr: Mapping[str, Any], named_types: Mapping[str, Any]
) -> Mapping[str, Any]:
    if expr["kind"] == "ref":
        return _resolved_expr(named_types[expr["name"]], named_types)
    if expr["kind"] == "alias":
        return _resolved_expr(expr["target"], named_types)
    return expr


def _literal_discriminators(
    expr: Mapping[str, Any], named_types: Mapping[str, Any]
) -> list[tuple[str, Any]]:
    resolved = _resolved_expr(expr, named_types)
    if resolved["kind"] != "object":
        return []
    return [
        (wire_name, field["type"]["value"])
        for wire_name, field in resolved["fields"].items()
        if field["presence"] == "required" and field["type"]["kind"] == "literal"
    ]


def _render_untagged_union(
    name: str,
    expr: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> list[str]:
    variants = list(expr["variants"])
    lines = [
        f"type {name} struct {{",
        "\tValue any `json:\"-\"`",
        "\tRaw json.RawMessage `json:\"-\"`",
        "}",
        "",
        f"func (value *{name}) UnmarshalJSON(data []byte) error {{",
        "\tvalue.Raw = append(value.Raw[:0], data...)",
        "\tvar fields map[string]json.RawMessage",
        "\tif err := decodeJSON(data, &fields); err != nil {",
        "\t\treturn err",
        "\t}",
    ]
    ordered = sorted(
        enumerate(variants),
        key=lambda item: (
            not bool(_literal_discriminators(item[1], named_types)),
            item[0],
        ),
    )
    fallback: tuple[int, Mapping[str, Any]] | None = None
    for index, variant in ordered:
        discriminators = _literal_discriminators(variant, named_types)
        if not discriminators:
            if fallback is None:
                fallback = (index, variant)
            continue
        conditions: list[str] = []
        for wire_name, literal in discriminators:
            encoded = json.dumps(literal, ensure_ascii=False, separators=(",", ":"))
            conditions.append(
                f"bytes.Equal(bytes.TrimSpace(fields[{_go_string(wire_name)}]), "
                f"[]byte({_go_string(encoded)}))"
            )
        variant_type = _go_type(variant)
        lines.extend(
            [
                f"\tif {' && '.join(conditions)} {{",
                f"\t\tvar decoded {variant_type}",
                "\t\tif err := decodeJSON(data, &decoded); err != nil { return err }",
                "\t\tvalue.Value = decoded",
                "\t\treturn nil",
                "\t}",
            ]
        )
    if fallback is not None:
        _index, variant = fallback
        variant_type = _go_type(variant)
        lines.extend(
            [
                f"\tvar decoded {variant_type}",
                "\tif err := decodeJSON(data, &decoded); err != nil { return err }",
                "\tvalue.Value = decoded",
                "\treturn nil",
            ]
        )
    else:
        lines.extend(["\tvalue.Value = nil", "\treturn nil"])
    lines.extend(
        [
            "}",
            "",
            f"func (value {name}) MarshalJSON() ([]byte, error) {{",
            "\tif value.Value != nil { return json.Marshal(value.Value) }",
            "\tif value.Raw != nil { return value.Raw, nil }",
            "\treturn []byte(\"null\"), nil",
            "}",
        ]
    )
    for variant in variants:
        variant_type = _go_type(variant)
        accessor = _go_name(
            variant["name"] if variant["kind"] == "ref" else variant_type
        )
        lines.extend(
            [
                "",
                f"func (value {name}) As{accessor}() ({variant_type}, bool) {{",
                f"\tdecoded, ok := value.Value.({variant_type})",
                "\treturn decoded, ok",
                "}",
            ]
        )
    return lines


def _render_named_type(
    name: str,
    expr: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> list[str]:
    go_name = _go_name(name)
    kind = expr["kind"]
    if kind == "object":
        return _render_object(go_name, expr)
    if kind == "tagged_union":
        return _render_tagged_union(go_name, expr)
    if kind == "enum":
        base = _enum_base(list(expr["values"]))
        lines = [f"type {go_name} {base}", "", "const ("]
        for value in expr["values"]:
            constant = go_name + _go_name(str(value))
            literal = json.dumps(value, ensure_ascii=False)
            lines.append(f"\t{constant} {go_name} = {literal}")
        lines.append(")")
        return lines
    if kind == "literal":
        return [f"type {go_name} = {_underlying_literal_type(expr['value'])}"]
    if kind == "opaque_json":
        return [f"type {go_name} = json.RawMessage"]
    if kind == "untagged_union":
        return _render_untagged_union(go_name, expr, named_types)
    return [f"type {go_name} = {_go_type(expr)}"]


def _header(ir: SdkIR) -> list[str]:
    return [
        "// Code generated by cmux-tui SDK codegen. DO NOT EDIT.",
        f"// Mux protocol {ir.mux_protocol}; IR SHA-256 {ir.ir_sha256}.",
        "",
    ]


def _gofmt(source: str) -> str:
    try:
        completed = subprocess.run(
            ["gofmt"],
            input=source.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as error:
        raise ValueError("Go SDK generation requires gofmt on PATH") from error
    except subprocess.CalledProcessError as error:
        details = error.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"gofmt rejected generated Go source: {details}") from error
    return completed.stdout.decode("utf-8")


def _render_types(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = _header(ir)
    lines.extend(
        [
            "package cmux",
            "",
            "import (",
            '\t"bytes"',
            '\t"encoding/json"',
            ")",
            "",
        ]
    )
    for name, expr in document["types"].items():
        lines.extend(_render_named_type(name, expr, document["types"]))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _request_expr(command: Mapping[str, Any]) -> Mapping[str, Any]:
    request = dict(command["request"])
    request["fields"] = {
        name: field
        for name, field in request["fields"].items()
        if name not in {"cmd", "id"}
    }
    return request


def _result_name(wire_name: str) -> str:
    return _go_name(wire_name) + "Result"


def _request_name(wire_name: str) -> str:
    return _go_name(wire_name) + "Request"


def _options_name(wire_name: str) -> str:
    return _go_name(wire_name) + "Options"


def _is_empty_result(
    expr: Mapping[str, Any], named_types: Mapping[str, Any]
) -> bool:
    if expr["kind"] == "ref":
        return _is_empty_result(named_types[expr["name"]], named_types)
    if expr["kind"] == "alias":
        return _is_empty_result(expr["target"], named_types)
    return (
        expr["kind"] == "object"
        and not expr["fields"]
        and not expr["additional_properties"]
    )


def _is_simple_argument(
    expr: Mapping[str, Any], named_types: Mapping[str, Any]
) -> bool:
    kind = expr["kind"]
    if kind in {"scalar", "literal", "enum"}:
        return True
    if kind in {"alias"}:
        return _is_simple_argument(expr["target"], named_types)
    if kind == "ref":
        return _is_simple_argument(named_types[expr["name"]], named_types)
    return False


def _render_command_types(
    wire_name: str,
    command: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> list[str]:
    request = _request_expr(command)
    request_name = _request_name(wire_name)
    result_name = _result_name(wire_name)
    lines = [
        f"// {request_name} is the exact {wire_name} wire payload.",
        *_render_object(request_name, request),
        "",
    ]
    if result_name not in {_go_name(name) for name in named_types}:
        result = command["result"]
        if result["kind"] == "object":
            lines.extend(_render_object(result_name, result))
        else:
            lines.append(f"type {result_name} = {_go_type(result)}")
    return lines


def _method_shape(
    wire_name: str,
    command: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> tuple[str, list[tuple[str, str]], str]:
    request = _request_expr(command)
    required = sorted(
        [
        (name, field)
        for name, field in request["fields"].items()
        if field["presence"] == "required"
        ],
        key=lambda item: (_ARGUMENT_ORDER.get(item[0], 100), item[0]),
    )
    optional = [
        (name, field)
        for name, field in request["fields"].items()
        if field["presence"] == "optional"
    ]
    simple = len(required) <= 3 and all(
        _is_simple_argument(field["type"], named_types) for _, field in required
    )
    if not simple:
        return (
            "request",
            [("request", _request_name(wire_name))],
            "commandMap(request)",
        )

    arguments = [
        (
            _lower_go_name(name),
            _field_type(
                {**field, "presence": "required", "nullable": field["nullable"]}
            ),
        )
        for name, field in required
    ]
    if optional:
        arguments.append(("options", _options_name(wire_name)))
    if not required and optional:
        params = "commandMap(options)"
    elif required:
        entries = ", ".join(
            f"{_go_string(name)}: {_lower_go_name(name)}" for name, _ in required
        )
        if optional:
            params = f"mergeCommandParams(map[string]any{{{entries}}}, options)"
        else:
            params = f"map[string]any{{{entries}}}"
    else:
        params = "nil"
    return "shaped", arguments, params


def _lower_go_name(value: str) -> str:
    rendered = _go_name(value)
    if rendered in _ACRONYMS.values():
        return rendered.lower()
    return rendered[:1].lower() + rendered[1:]


def _render_options_type(
    wire_name: str, command: Mapping[str, Any]
) -> list[str]:
    optional = {
        name: field
        for name, field in _request_expr(command)["fields"].items()
        if field["presence"] == "optional"
    }
    if not optional or wire_name in _SPECIAL_METHODS:
        return []
    return _render_object(
        _options_name(wire_name),
        {
            "kind": "object",
            "fields": optional,
            "additional_properties": False,
        },
    )


def _render_method(
    wire_name: str,
    command: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> list[str]:
    if wire_name in _SPECIAL_METHODS:
        return []
    name = _go_name(wire_name)
    _shape, arguments, params = _method_shape(wire_name, command, named_types)
    signature_args = ", ".join(
        ["ctx context.Context", *(f"{arg} {typ}" for arg, typ in arguments)]
    )
    result_name = _result_name(wire_name)
    empty = _is_empty_result(command["result"], named_types)
    returns = "error" if empty else f"({result_name}, error)"
    lines = [
        f"// {name} sends {wire_name}. Protocol v{command['since']}; "
        f"authority {command['authority']}.",
        f"func (c *Client) {name}({signature_args}) {returns} {{",
    ]
    if not empty:
        lines.append(f"\tvar result {result_name}")
    lines.append(
        f"\terr := c.requestGenerated(ctx, commandMetadata[{_go_string(wire_name)}], "
        f"{_go_string(wire_name)}, {params}, "
        + ("nil)" if empty else "&result)")
    )
    if empty:
        lines.append("\treturn err")
    else:
        lines.append("\treturn result, err")
    lines.append("}")
    return lines


def _render_commands(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = _header(ir)
    lines.extend(["package cmux", "", 'import "context"', ""])
    for wire_name, command in document["commands"].items():
        lines.extend(_render_command_types(wire_name, command, document["types"]))
        lines.append("")
        lines.extend(_render_options_type(wire_name, command))
        if _render_options_type(wire_name, command):
            lines.append("")
    for wire_name, command in document["commands"].items():
        lines.extend(_render_method(wire_name, command, document["types"]))
        if wire_name not in _SPECIAL_METHODS:
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _event_name(wire_name: str) -> str:
    return _go_name(wire_name) + "Event"


def _event_memberships(event: Mapping[str, Any]) -> set[str]:
    streams = set(event["streams"])
    memberships: set[str] = set()
    if any(stream.startswith("subscribe") for stream in streams):
        memberships.add("SubscribeEvent")
        memberships.add("DeltaEvent")
    if any(stream.startswith("attach-") for stream in streams):
        memberships.add("AttachEvent")
    if "attach-byte" in streams:
        memberships.add("ByteAttachEvent")
    if "attach-render" in streams:
        memberships.add("RenderAttachEvent")
    if "attach-browser" in streams:
        memberships.add("BrowserAttachEvent")
    return memberships


def _render_event_type(
    wire_name: str, event: Mapping[str, Any]
) -> list[str]:
    payload = dict(event["payload"])
    payload["fields"] = {
        name: field for name, field in payload["fields"].items() if name != "event"
    }
    name = _event_name(wire_name)
    lines = [
        f"// {name} is emitted by protocol v{event['since']}.",
        *_render_object(name, payload),
        "",
        f"func ({name}) EventName() string {{ return {_go_string(wire_name)} }}",
    ]
    marker_names = {
        "SubscribeEvent": "isSubscribeEvent",
        "DeltaEvent": "isDeltaEvent",
        "AttachEvent": "isAttachEvent",
        "ByteAttachEvent": "isByteAttachEvent",
        "RenderAttachEvent": "isRenderAttachEvent",
        "BrowserAttachEvent": "isBrowserAttachEvent",
    }
    for membership in sorted(_event_memberships(event)):
        lines.append(f"func ({name}) {marker_names[membership]}() {{}}")
    return lines


def _render_event_decode_case(
    wire_name: str, event: Mapping[str, Any]
) -> list[str]:
    lines = [f"\tcase {_go_string(wire_name)}:"]
    payload_fields = event["payload"]["fields"]
    for canonical, field in payload_fields.items():
        aliases = field.get("aliases", [])
        if not aliases:
            continue
        lines.append(f'\t\tif _, exists := raw[{_go_string(canonical)}]; !exists {{')
        for alias in aliases:
            lines.extend(
                [
                    f'\t\t\tif value, found := raw[{_go_string(alias)}]; found {{',
                    f'\t\t\t\traw[{_go_string(canonical)}] = value',
                    "\t\t\t}",
                ]
            )
        lines.append("\t\t}")
    name = _event_name(wire_name)
    lines.extend(
        [
            f"\t\tvar event {name}",
            "\t\tif decodeEvent(raw, &event) {",
            "\t\t\treturn event",
            "\t\t}",
        ]
    )
    return lines


def _render_events(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = _header(ir)
    lines.extend(
        [
            "package cmux",
            "",
            "import (",
            '\t"context"',
            '\t"fmt"',
            ")",
            "",
            "type Event interface {",
            "\tEventName() string",
            "}",
            "",
            "type SubscribeEvent interface { Event; isSubscribeEvent() }",
            "type DeltaEvent interface { Event; isDeltaEvent() }",
            "type AttachEvent interface { Event; isAttachEvent() }",
            "type ByteAttachEvent interface { Event; isByteAttachEvent() }",
            "type RenderAttachEvent interface { Event; isRenderAttachEvent() }",
            "type BrowserAttachEvent interface { Event; isBrowserAttachEvent() }",
            "",
        ]
    )
    for wire_name, event in document["events"].items():
        lines.extend(_render_event_type(wire_name, event))
        lines.append("")
    lines.extend(
        [
            "type UnknownEvent struct {",
            "\tName string",
            "\tRaw map[string]any",
            "}",
            "",
            "func (event UnknownEvent) EventName() string { return event.Name }",
            "func (UnknownEvent) isSubscribeEvent() {}",
            "func (UnknownEvent) isDeltaEvent() {}",
            "func (UnknownEvent) isAttachEvent() {}",
            "func (UnknownEvent) isByteAttachEvent() {}",
            "func (UnknownEvent) isRenderAttachEvent() {}",
            "func (UnknownEvent) isBrowserAttachEvent() {}",
            "",
            "func parseEvent(raw map[string]any) Event {",
            '\tname, _ := raw["event"].(string)',
            "\tswitch name {",
        ]
    )
    for wire_name, event in document["events"].items():
        lines.extend(_render_event_decode_case(wire_name, event))
    lines.extend(
        [
            "\t}",
            "\treturn UnknownEvent{Name: name, Raw: raw}",
            "}",
            "",
            "func (stream *Stream) RecvSubscribe(ctx context.Context) (SubscribeEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(SubscribeEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not a subscribe event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
            "",
            "func (stream *Stream) RecvDelta(ctx context.Context) (DeltaEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(DeltaEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not a delta event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
            "",
            "func (stream *Stream) RecvAttach(ctx context.Context) (AttachEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(AttachEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not an attach event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
            "",
            "func (stream *Stream) RecvByte(ctx context.Context) (ByteAttachEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(ByteAttachEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not a byte attach event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
            "",
            "func (stream *Stream) RecvRender(ctx context.Context) (RenderAttachEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(RenderAttachEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not a render attach event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
            "",
            "func (stream *Stream) RecvBrowser(ctx context.Context) (BrowserAttachEvent, error) {",
            "\tevent, err := stream.Recv(ctx)",
            "\tif err != nil { return nil, err }",
            "\ttyped, ok := event.(BrowserAttachEvent)",
            '\tif !ok { return nil, fmt.Errorf("%w: %s is not a browser attach event", ErrDecode, event.EventName()) }',
            "\treturn typed, nil",
            "}",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def _render_metadata(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = _header(ir)
    lines.extend(
        [
            "package cmux",
            "",
            "const (",
            f"\tSDKSchemaVersion = {ir.schema_version}",
            f"\tMuxProtocolVersion = {ir.mux_protocol}",
            f"\tSDKIRSHA256 = {_go_string(ir.ir_sha256)}",
            ")",
            "",
            "type Authority string",
            "",
            "const (",
        ]
    )
    authorities = sorted(
        {command["authority"] for command in document["commands"].values()}
    )
    for authority in authorities:
        lines.append(
            f"\tAuthority{_go_name(authority)} Authority = {_go_string(authority)}"
        )
    lines.extend(
        [
            ")",
            "",
            "type CommandMetadata struct {",
            "\tName string",
            "\tGoMethod string",
            "\tAuthority Authority",
            "\tSince uint32",
            "\tCapability string",
            "\tStream string",
            "\tFieldSince map[string]uint32",
            "\tFieldCapabilities map[string]string",
            "}",
            "",
            "type EventMetadata struct {",
            "\tName string",
            "\tSince uint32",
            "\tCapability string",
            "\tStreams []string",
            "\tEmission string",
            "}",
            "",
            "type Profile string",
            "",
            "const (",
        ]
    )
    for profile in document["profiles"]:
        lines.append(
            f"\tProfile{_go_name(profile)} Profile = {_go_string(profile)}"
        )
    lines.extend(
        [
            ")",
            "",
            "type ProfileMetadata struct {",
            "\tName Profile",
            "\tDescription string",
            "\tInherits []Profile",
            "\tTransport string",
            "\tRequiresAuthority bool",
            "}",
            "",
            "var profileMetadata = map[Profile]ProfileMetadata{",
        ]
    )
    for profile_name, profile in document["profiles"].items():
        inherits = ", ".join(
            f"Profile{_go_name(value)}" for value in profile["inherits"]
        )
        lines.append(
            f"\tProfile{_go_name(profile_name)}: "
            f"{{Name: Profile{_go_name(profile_name)}, "
            f"Description: {_go_string(profile['description'])}, "
            f"Inherits: []Profile{{{inherits}}}, "
            f"Transport: {_go_string(profile.get('transport', ''))}, "
            f"RequiresAuthority: {str(profile.get('requires_authority', False)).lower()}}},"
        )
    lines.extend(
        [
            "}",
            "",
            "var commandMetadata = map[string]CommandMetadata{",
        ]
    )
    for wire_name, command in document["commands"].items():
        capability = command["capability"] or ""
        stream = command["stream"]["kind"] if command["stream"] else ""
        field_since = {
            name: field["since"]
            for name, field in _request_expr(command)["fields"].items()
            if "since" in field
        }
        field_capabilities = {
            name: field["capability"]
            for name, field in _request_expr(command)["fields"].items()
            if "capability" in field
        }
        lines.append(
            f"\t{_go_string(wire_name)}: {{Name: {_go_string(wire_name)}, "
            f"GoMethod: {_go_string(_go_name(wire_name))}, "
            f"Authority: Authority{_go_name(command['authority'])}, "
            f"Since: {command['since']}, Capability: {_go_string(capability)}, "
            f"Stream: {_go_string(stream)}, "
            f"FieldSince: {_go_map(field_since, 'uint32')}, "
            f"FieldCapabilities: {_go_map(field_capabilities, 'string')}}},"
        )
    lines.extend(["}", "", "var eventMetadata = map[string]EventMetadata{"])
    for wire_name, event in document["events"].items():
        capability = event["capability"] or ""
        streams = ", ".join(_go_string(value) for value in event["streams"])
        lines.append(
            f"\t{_go_string(wire_name)}: {{Name: {_go_string(wire_name)}, "
            f"Since: {event['since']}, Capability: {_go_string(capability)}, "
            f"Streams: []string{{{streams}}}, Emission: "
            f"{_go_string(event['emission'])}}},"
        )
    lines.extend(
        [
            "}",
            "",
            "func CommandInfo(name string) (CommandMetadata, bool) {",
            "\tmetadata, ok := commandMetadata[name]",
            "\tif ok { metadata = cloneCommandMetadata(metadata) }",
            "\treturn metadata, ok",
            "}",
            "",
            "func cloneCommandMetadata(metadata CommandMetadata) CommandMetadata {",
            "\tif metadata.FieldSince != nil {",
            "\t\tvalues := metadata.FieldSince",
            "\t\tmetadata.FieldSince = make(map[string]uint32, len(metadata.FieldSince))",
            "\t\tfor name, since := range values {",
            "\t\t\tmetadata.FieldSince[name] = since",
            "\t\t}",
            "\t}",
            "\tif metadata.FieldCapabilities != nil {",
            "\t\tvalues := metadata.FieldCapabilities",
            "\t\tmetadata.FieldCapabilities = make(map[string]string, len(metadata.FieldCapabilities))",
            "\t\tfor name, capability := range values {",
            "\t\t\tmetadata.FieldCapabilities[name] = capability",
            "\t\t}",
            "\t}",
            "\treturn metadata",
            "}",
            "",
            "func EventInfo(name string) (EventMetadata, bool) {",
            "\tmetadata, ok := eventMetadata[name]",
            "\tif ok { metadata.Streams = append([]string(nil), metadata.Streams...) }",
            "\treturn metadata, ok",
            "}",
            "",
            "func ProfileInfo(name Profile) (ProfileMetadata, bool) {",
            "\tmetadata, ok := profileMetadata[name]",
            "\tif ok { metadata.Inherits = append([]Profile(nil), metadata.Inherits...) }",
            "\treturn metadata, ok",
            "}",
            "",
            "func AllCommandMetadata() []CommandMetadata {",
            f"\tresult := make([]CommandMetadata, 0, {len(document['commands'])})",
        ]
    )
    for wire_name in document["commands"]:
        lines.append(
            f"\tresult = append(result, "
            f"cloneCommandMetadata(commandMetadata[{_go_string(wire_name)}]))"
        )
    lines.extend(["\treturn result", "}", "", "func AllEventMetadata() []EventMetadata {"])
    lines.append(
        f"\tresult := make([]EventMetadata, 0, {len(document['events'])})"
    )
    lines.append("\tvar metadata EventMetadata")
    for wire_name in document["events"]:
        lines.append(
            f"\tmetadata = eventMetadata[{_go_string(wire_name)}]; "
            "metadata.Streams = append([]string(nil), metadata.Streams...); "
            "result = append(result, metadata)"
        )
    lines.extend(["\treturn result", "}"])
    return "\n".join(lines).rstrip() + "\n"


def emit(ir: SdkIR) -> Mapping[str | PurePosixPath, str | bytes]:
    document = _plain(ir.document)
    return {
        "generated_commands.go": _gofmt(_render_commands(ir, document)),
        "generated_events.go": _gofmt(_render_events(ir, document)),
        "generated_metadata.go": _gofmt(_render_metadata(ir, document)),
        "generated_types.go": _gofmt(_render_types(ir, document)),
    }


EMITTER = Emitter(
    language="go",
    output_root=PurePosixPath("go"),
    render=emit,
)
