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


def _go_literal(value: Any) -> str:
    if value is None:
        return "nil"
    return json.dumps(value, ensure_ascii=False)


def _render_constrained_type(name: str, expr: Mapping[str, Any]) -> list[str]:
    kind = expr["kind"]
    if kind == "literal":
        values = [expr["value"]]
    elif kind == "enum":
        values = list(expr["values"])
    else:
        raise ValueError(f"unsupported constrained Go type kind: {kind}")

    base = _enum_base(values)
    lines = [f"type {name} {base}", "", "const ("]
    for value in values:
        constant = name + _go_name(str(value))
        lines.append(f"\t{constant} {name} = {_go_literal(value)}")
    lines.extend(
        [
            ")",
            "",
            f"func (value {name}) valid() bool {{",
            "\tswitch value {",
            "\tcase " + ", ".join(name + _go_name(str(value)) for value in values) + ":",
            "\t\treturn true",
            "\tdefault:",
            "\t\treturn false",
            "\t}",
            "}",
            "",
            f"func (value {name}) MarshalJSON() ([]byte, error) {{",
            "\tif !value.valid() {",
            f'\t\treturn nil, fmt.Errorf("%s has invalid value %v", {_go_string(name)}, value)',
            "\t}",
            f"\treturn json.Marshal({base}(value))",
            "}",
            "",
            f"func (value *{name}) UnmarshalJSON(data []byte) error {{",
            f"\tvar decoded {base}",
            "\tif err := json.Unmarshal(data, &decoded); err != nil {",
            "\t\treturn err",
            "\t}",
            f"\tcandidate := {name}(decoded)",
            "\tif !candidate.valid() {",
            f'\t\treturn fmt.Errorf("%s has invalid value %v", {_go_string(name)}, decoded)',
            "\t}",
            "\t*value = candidate",
            "\treturn nil",
            "}",
        ]
    )
    return lines


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


def _inline_constraint(
    expr: Mapping[str, Any],
) -> Mapping[str, Any] | None:
    if expr["kind"] == "alias":
        return _inline_constraint(expr["target"])
    if expr["kind"] in {"enum", "literal"}:
        return expr
    return None


def _inline_named_constraint(
    expr: Mapping[str, Any],
) -> Mapping[str, Any] | None:
    constraint = _inline_constraint(expr)
    if constraint is None:
        return None
    values = (
        [constraint["value"]]
        if constraint["kind"] == "literal"
        else list(constraint["values"])
    )
    if _enum_base(values) == "bool":
        return None
    return constraint


def _field_value_type(
    owner_name: str | None,
    wire_name: str | None,
    field: Mapping[str, Any],
    *,
    indent: str = "",
) -> str:
    expr = field["type"]
    if owner_name and wire_name and _inline_named_constraint(expr) is not None:
        return owner_name + _go_name(wire_name)
    return _go_type(expr, anonymous_indent=indent)


def _field_type(
    field: Mapping[str, Any],
    *,
    owner_name: str | None = None,
    wire_name: str | None = None,
    indent: str = "",
) -> str:
    value_type = _field_value_type(
        owner_name,
        wire_name,
        field,
        indent=indent,
    )
    if field["nullable"]:
        if field["presence"] == "optional":
            return f"Presence[{value_type}]"
        return f"RequiredNullable[{value_type}]"
    rendered = value_type
    if field["presence"] == "optional":
        rendered = "*" + rendered
    return rendered


def _field_tag(wire_name: str, field: Mapping[str, Any]) -> str:
    if field["nullable"]:
        return '`json:"-"`'
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


def _render_inline_constrained_type(
    owner_name: str,
    wire_name: str,
    field: Mapping[str, Any],
) -> list[str]:
    constraint = _inline_named_constraint(field["type"])
    if constraint is None:
        return []
    name = owner_name + _go_name(wire_name)
    return _render_constrained_type(name, constraint)


def _nullable_fields(
    expr: Mapping[str, Any],
) -> list[tuple[str, Mapping[str, Any]]]:
    return [
        (wire_name, field)
        for wire_name, field in expr["fields"].items()
        if field["nullable"]
    ]


def _render_decoded_constraint_validation(
    model_name: str,
    wire_name: str,
    expr: Mapping[str, Any],
    decoded_value: str,
    indent: str,
) -> list[str]:
    constraint = _inline_constraint(expr)
    if constraint is None:
        return []

    go_name = _go_name(wire_name)
    context = f"decode {model_name}.{go_name}"
    if constraint["kind"] == "literal":
        values = [constraint["value"]]
    else:
        values = list(constraint["values"])
    allowed = ", ".join(_go_literal(item) for item in values)
    return [
        f"{indent}switch {decoded_value} {{",
        f"{indent}case {allowed}:",
        f"{indent}default:",
        f'{indent}\treturn fmt.Errorf("{context}: invalid value %v", {decoded_value})',
        f"{indent}}}",
    ]


def _render_encoded_constraint_validation(
    model_name: str,
    wire_name: str,
    expr: Mapping[str, Any],
    encoded_value: str,
    indent: str,
) -> list[str]:
    constraint = _inline_constraint(expr)
    if constraint is None:
        return []

    go_name = _go_name(wire_name)
    context = f"encode {model_name}.{go_name}"
    if constraint["kind"] == "literal":
        values = [constraint["value"]]
    else:
        values = list(constraint["values"])
    allowed = ", ".join(_go_literal(item) for item in values)
    return [
        f"{indent}switch {encoded_value} {{",
        f"{indent}case {allowed}:",
        f"{indent}default:",
        f'{indent}\treturn nil, fmt.Errorf("{context}: invalid value %v", {encoded_value})',
        f"{indent}}}",
    ]


def _render_object_json(
    name: str,
    expr: Mapping[str, Any],
) -> list[str]:
    nullable = _nullable_fields(expr)
    constrained = [
        (wire_name, field)
        for wire_name, field in expr["fields"].items()
        if _inline_constraint(field["type"]) is not None
    ]
    additional = bool(expr["additional_properties"])

    lines: list[str] = []
    if nullable or additional or constrained:
        lines.append(f"func (value {name}) MarshalJSON() ([]byte, error) {{")
        for wire_name, field in constrained:
            go_name = _go_name(wire_name)
            if field["nullable"]:
                lines.append(
                    f"\tif fieldValue, ok := value.{go_name}.Get(); ok {{"
                )
                lines.extend(
                    _render_encoded_constraint_validation(
                        name,
                        wire_name,
                        field["type"],
                        "fieldValue",
                        "\t\t",
                    )
                )
                lines.append("\t}")
            elif field["presence"] == "optional":
                lines.append(f"\tif value.{go_name} != nil {{")
                lines.extend(
                    _render_encoded_constraint_validation(
                        name,
                        wire_name,
                        field["type"],
                        f"*value.{go_name}",
                        "\t\t",
                    )
                )
                lines.append("\t}")
            else:
                lines.extend(
                    _render_encoded_constraint_validation(
                        name,
                        wire_name,
                        field["type"],
                        f"value.{go_name}",
                        "\t",
                    )
                )
        lines.append(f"\ttype wire {name}")
        if not nullable and not additional:
            lines.extend(
                [
                    "\treturn json.Marshal(wire(value))",
                    "}",
                    "",
                ]
            )
        else:
            lines.extend(
                [
                    "\tencoded, err := json.Marshal(wire(value))",
                    "\tif err != nil {",
                    "\t\treturn nil, err",
                    "\t}",
                    "\tvar object map[string]json.RawMessage",
                    "\tif err := json.Unmarshal(encoded, &object); err != nil {",
                    "\t\treturn nil, err",
                    "\t}",
                ]
            )
        if additional:
            lines.append("\tfor key, fieldValue := range value.Additional {")
            if expr["fields"]:
                known_fields = ", ".join(
                    _go_string(wire_name) for wire_name in expr["fields"]
                )
                lines.extend(
                    [
                        "\t\tswitch key {",
                        f"\t\tcase {known_fields}:",
                        "\t\t\tcontinue",
                        "\t\t}",
                    ]
                )
            lines.extend(
                [
                    "\t\tobject[key] = append(json.RawMessage(nil), fieldValue...)",
                    "\t}",
                ]
            )
        for wire_name, field in nullable:
            go_name = _go_name(wire_name)
            if field["presence"] == "optional":
                lines.extend(
                    [
                        f"\tif value.{go_name}.IsAbsent() {{",
                        f"\t\tdelete(object, {_go_string(wire_name)})",
                        f"\t}} else if value.{go_name}.IsNull() {{",
                        f"\t\tobject[{_go_string(wire_name)}] = json.RawMessage(\"null\")",
                        "\t} else {",
                        f"\t\tfieldValue, _ := value.{go_name}.Get()",
                        "\t\tencodedField, err := json.Marshal(fieldValue)",
                        "\t\tif err != nil {",
                        f'\t\t\treturn nil, fmt.Errorf("encode {name}.{go_name}: %w", err)',
                        "\t\t}",
                        f"\t\tobject[{_go_string(wire_name)}] = encodedField",
                        "\t}",
                    ]
                )
            else:
                lines.extend(
                    [
                        f"\tif !value.{go_name}.IsSet() {{",
                        f'\t\treturn nil, fmt.Errorf("encode {name}: required nullable field '
                        f'{wire_name} is missing")',
                        "\t}",
                        f"\tif value.{go_name}.IsNull() {{",
                        f"\t\tobject[{_go_string(wire_name)}] = json.RawMessage(\"null\")",
                        "\t} else {",
                        f"\t\tfieldValue, _ := value.{go_name}.Get()",
                        "\t\tencodedField, err := json.Marshal(fieldValue)",
                        "\t\tif err != nil {",
                        f'\t\t\treturn nil, fmt.Errorf("encode {name}.{go_name}: %w", err)',
                        "\t\t}",
                        f"\t\tobject[{_go_string(wire_name)}] = encodedField",
                        "\t}",
                    ]
                )
        if nullable or additional:
            lines.extend(["\treturn json.Marshal(object)", "}", ""])

    lines.extend(
        [
            f"func (value *{name}) UnmarshalJSON(data []byte) error {{",
            "\tif !isJSONObject(data) {",
            f'\t\treturn fmt.Errorf("decode {name}: expected object")',
            "\t}",
            "\tvar fields struct {",
        ]
    )
    for wire_name, field in expr["fields"].items():
        go_name = _go_name(wire_name)
        if field["nullable"]:
            value_type = _field_value_type(
                name,
                wire_name,
                field,
                indent="\t\t",
            )
            decoded_type = (
                f"Presence[{value_type}]"
                if field["presence"] == "optional"
                else f"RequiredNullable[{value_type}]"
            )
        elif field["presence"] == "optional":
            decoded_type = (
                "optionalNonNullJSON["
                + _field_value_type(
                    name,
                    wire_name,
                    field,
                    indent="\t\t",
                )
                + "]"
            )
        else:
            decoded_type = (
                "*"
                + _field_value_type(
                    name,
                    wire_name,
                    field,
                    indent="\t\t",
                )
            )
        lines.append(
            f"\t\t{go_name} {decoded_type} "
            f'`json:"{wire_name}"`'
        )
    lines.extend(
        [
            "\t}",
            "\tif err := json.Unmarshal(data, &fields); err != nil {",
            f'\t\treturn fmt.Errorf("decode {name}: %w", err)',
            "\t}",
            f"\ttype wire {name}",
            "\tvar decoded wire",
        ]
    )
    for wire_name, field in expr["fields"].items():
        go_name = _go_name(wire_name)
        if field["nullable"]:
            if field["presence"] == "required":
                lines.extend(
                    [
                        f"\tif !fields.{go_name}.IsSet() {{",
                        f'\t\treturn fmt.Errorf("decode {name}: required field '
                        f'{wire_name} is missing")',
                        "\t}",
                    ]
                )
            lines.append(f"\tdecoded.{go_name} = fields.{go_name}")
        elif field["presence"] == "optional":
            lines.extend(
                [
                    f"\tif fields.{go_name}.null {{",
                    f'\t\treturn fmt.Errorf("decode {name}: non-nullable field '
                    f'{wire_name} is null")',
                    "\t}",
                    f"\tif fields.{go_name}.set {{",
                    f"\t\tdecoded.{go_name} = &fields.{go_name}.value",
                ]
            )
            lines.extend(
                _render_decoded_constraint_validation(
                    name,
                    wire_name,
                    field["type"],
                    f"*decoded.{go_name}",
                    "\t\t",
                )
            )
            lines.append("\t}")
        else:
            lines.extend(
                [
                    f"\tif fields.{go_name} == nil {{",
                    f'\t\treturn fmt.Errorf("decode {name}: required field '
                    f'{wire_name} is missing or null")',
                    "\t}",
                    f"\tdecoded.{go_name} = *fields.{go_name}",
                ]
            )
            lines.extend(
                _render_decoded_constraint_validation(
                    name,
                    wire_name,
                    field["type"],
                    f"decoded.{go_name}",
                    "\t",
                )
            )
    if additional:
        lines.extend(
            [
                "\tvar object map[string]json.RawMessage",
                "\tif err := json.Unmarshal(data, &object); err != nil {",
                f'\t\treturn fmt.Errorf("decode {name}: %w", err)',
                "\t}",
                "\tfor key, fieldValue := range object {",
            ]
        )
        if expr["fields"]:
            known_fields = ", ".join(
                _go_string(wire_name) for wire_name in expr["fields"]
            )
            lines.extend(
                [
                    "\t\tswitch key {",
                    f"\t\tcase {known_fields}:",
                    "\t\t\tcontinue",
                    "\t\t}",
                ]
            )
        lines.extend(
            [
                "\t\tif decoded.Additional == nil {",
                "\t\t\tdecoded.Additional = make(map[string]json.RawMessage)",
                "\t\t}",
                "\t\tdecoded.Additional[key] = append(",
                "\t\t\tjson.RawMessage(nil), fieldValue...",
                "\t\t)",
                "\t}",
            ]
        )
    lines.extend([f"\t*value = {name}(decoded)", "\treturn nil", "}"])
    return lines


def _render_object(name: str, expr: Mapping[str, Any]) -> list[str]:
    lines: list[str] = []
    for wire_name, field in expr["fields"].items():
        declarations = _render_inline_constrained_type(
            name,
            wire_name,
            field,
        )
        if declarations:
            lines.extend(declarations)
            lines.append("")
    lines.append(f"type {name} struct {{")
    for wire_name, field in expr["fields"].items():
        lines.extend(_doc(field.get("description"), "\t"))
        lines.append(
            f"\t{_go_name(wire_name)} "
            f"{_field_type(field, owner_name=name, wire_name=wire_name, indent=chr(9))} "
            f"{_field_tag(wire_name, field)}"
        )
    if expr["additional_properties"]:
        lines.append('\tAdditional map[string]json.RawMessage `json:"-"`')
    lines.append("}")
    json_methods = _render_object_json(name, expr)
    if json_methods:
        lines.append("")
        lines.extend(json_methods)
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
            "\tvar fields map[string]json.RawMessage",
            "\tif err := decodeJSON(data, &fields); err != nil {",
            "\t\treturn err",
            "\t}",
            f"\trawTag, hasTag := fields[{_go_string(tag)}]",
            "\tif !hasTag {",
            f'\t\treturn fmt.Errorf("decode {name}: required field {tag} is missing")',
            "\t}",
            "\tif isJSONNull(rawTag) {",
            f'\t\treturn fmt.Errorf("decode {name}: non-nullable field {tag} is null")',
            "\t}",
            "\tvar decodedTag string",
            "\tif err := decodeJSON(rawTag, &decodedTag); err != nil {",
            f'\t\treturn fmt.Errorf("decode {name}.{_go_name(tag)}: %w", err)',
            "\t}",
            "\tvalue.Tag = decodedTag",
            "\tvalue.Raw = append(value.Raw[:0], data...)",
            "\tswitch decodedTag {",
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
    for tag_value, variant in expr["variants"].items():
        variant_name = _variant_name(name, str(tag_value))
        accessor = _go_name(str(tag_value))
        lines.extend(
            [
                "",
                f"func New{name}{accessor}(value {variant_name}) {name} {{",
            ]
        )
        if variant["kind"] == "object" and tag in variant["fields"]:
            tag_field = variant["fields"][tag]
            constraint = _inline_named_constraint(tag_field["type"])
            if constraint is not None and constraint["kind"] == "literal":
                constant = (
                    variant_name
                    + _go_name(tag)
                    + _go_name(str(constraint["value"]))
                )
                lines.append(
                    f"\tvalue.{_go_name(tag)} = {constant}"
                )
        lines.extend(
            [
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
        return _render_constrained_type(go_name, expr)
    if kind == "literal":
        return _render_constrained_type(go_name, expr)
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


def _render_presence_types() -> list[str]:
    return [
        "type presenceState uint8",
        "",
        "const (",
        "\tpresenceAbsent presenceState = iota",
        "\tpresenceNull",
        "\tpresenceValue",
        ")",
        "",
        "// Presence preserves all three states of an optional nullable JSON field.",
        "// Its zero value is absent.",
        "type Presence[T any] struct {",
        "\tstate presenceState",
        "\tvalue T",
        "}",
        "",
        "// Value returns a present, non-null optional value.",
        "func Value[T any](value T) Presence[T] {",
        "\treturn Presence[T]{state: presenceValue, value: value}",
        "}",
        "",
        "// Null returns a present, explicitly null optional value.",
        "func Null[T any]() Presence[T] {",
        "\treturn Presence[T]{state: presenceNull}",
        "}",
        "",
        "func (value Presence[T]) IsAbsent() bool { return value.state == presenceAbsent }",
        "func (value Presence[T]) IsNull() bool { return value.state == presenceNull }",
        "",
        "// Get returns the value and true only for a present, non-null value.",
        "func (value Presence[T]) Get() (T, bool) {",
        "\treturn value.value, value.state == presenceValue",
        "}",
        "",
        "func (value Presence[T]) MarshalJSON() ([]byte, error) {",
        "\tif value.state != presenceValue {",
        '\t\treturn []byte("null"), nil',
        "\t}",
        "\treturn json.Marshal(value.value)",
        "}",
        "",
        "func (value *Presence[T]) UnmarshalJSON(data []byte) error {",
        "\tif isJSONNull(data) {",
        "\t\t*value = Null[T]()",
        "\t\treturn nil",
        "\t}",
        "\tvar decoded T",
        "\tif err := json.Unmarshal(data, &decoded); err != nil {",
        "\t\treturn err",
        "\t}",
        "\t*value = Value(decoded)",
        "\treturn nil",
        "}",
        "",
        "// RequiredNullable preserves null versus value for a required JSON field.",
        "// Its zero value is unset and is rejected when encoded as a model field.",
        "type RequiredNullable[T any] struct {",
        "\tset bool",
        "\tnull bool",
        "\tvalue T",
        "}",
        "",
        "// RequiredValue returns a present, non-null required value.",
        "func RequiredValue[T any](value T) RequiredNullable[T] {",
        "\treturn RequiredNullable[T]{set: true, value: value}",
        "}",
        "",
        "// RequiredNull returns a present, explicitly null required value.",
        "func RequiredNull[T any]() RequiredNullable[T] {",
        "\treturn RequiredNullable[T]{set: true, null: true}",
        "}",
        "",
        "func (value RequiredNullable[T]) IsSet() bool { return value.set }",
        "func (value RequiredNullable[T]) IsNull() bool { return value.set && value.null }",
        "",
        "// Get returns the value and true only for a present, non-null value.",
        "func (value RequiredNullable[T]) Get() (T, bool) {",
        "\treturn value.value, value.set && !value.null",
        "}",
        "",
        "func (value RequiredNullable[T]) MarshalJSON() ([]byte, error) {",
        "\tif !value.set {",
        '\t\treturn nil, fmt.Errorf("required nullable value is unset")',
        "\t}",
        "\tif value.null {",
        '\t\treturn []byte("null"), nil',
        "\t}",
        "\treturn json.Marshal(value.value)",
        "}",
        "",
        "func (value *RequiredNullable[T]) UnmarshalJSON(data []byte) error {",
        "\tif isJSONNull(data) {",
        "\t\t*value = RequiredNull[T]()",
        "\t\treturn nil",
        "\t}",
        "\tvar decoded T",
        "\tif err := json.Unmarshal(data, &decoded); err != nil {",
        "\t\treturn err",
        "\t}",
        "\t*value = RequiredValue(decoded)",
        "\treturn nil",
        "}",
        "",
        "type optionalNonNullJSON[T any] struct {",
        "\tset bool",
        "\tnull bool",
        "\tvalue T",
        "}",
        "",
        "func (value *optionalNonNullJSON[T]) UnmarshalJSON(data []byte) error {",
        "\tvalue.set = true",
        "\tif isJSONNull(data) {",
        "\t\tvalue.null = true",
        "\t\treturn nil",
        "\t}",
        "\treturn json.Unmarshal(data, &value.value)",
        "}",
        "",
        "func isJSONObject(data []byte) bool {",
        "\ttrimmed := bytes.TrimSpace(data)",
        "\treturn len(trimmed) > 0 && trimmed[0] == '{'",
        "}",
        "",
        "func isJSONNull(data []byte) bool {",
        '\treturn bytes.Equal(bytes.TrimSpace(data), []byte("null"))',
        "}",
    ]


def _render_types(ir: SdkIR, document: Mapping[str, Any]) -> str:
    lines = _header(ir)
    lines.extend(
        [
            "package raw",
            "",
            "import (",
            '\t"bytes"',
            '\t"encoding/json"',
            '\t"fmt"',
            ")",
            "",
        ]
    )
    lines.extend(_render_presence_types())
    lines.append("")
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
) -> tuple[str, list[tuple[str, str]], str, bool]:
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
            True,
        )

    arguments = [
        (
            _lower_go_name(name),
            _field_type(
                {**field, "presence": "required", "nullable": field["nullable"]},
                owner_name=_request_name(wire_name),
                wire_name=name,
            ),
        )
        for name, field in required
    ]
    if optional:
        arguments.append(("options", _options_name(wire_name)))
    if not required and optional:
        params = "commandMap(options)"
        params_may_error = True
    elif required:
        entries = ", ".join(
            f"{_go_string(name)}: {_lower_go_name(name)}" for name, _ in required
        )
        if optional:
            params = f"mergeCommandParams(map[string]any{{{entries}}}, options)"
            params_may_error = True
        else:
            params = f"map[string]any{{{entries}}}"
            params_may_error = False
    else:
        params = "nil"
        params_may_error = False
    return "shaped", arguments, params, params_may_error


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


def _render_method_constraint_validation(
    command_name: str,
    wire_name: str,
    expr: Mapping[str, Any],
    encoded_value: str,
    indent: str,
    *,
    empty_result: bool,
) -> list[str]:
    constraint = _inline_constraint(expr)
    if constraint is None:
        return []
    if constraint["kind"] == "literal":
        values = [constraint["value"]]
    else:
        values = list(constraint["values"])
    allowed = ", ".join(_go_literal(item) for item in values)
    error = (
        f'fmt.Errorf("%w: encode {command_name}.{wire_name}: '
        f'invalid value %v", ErrInvalidArgument, {encoded_value})'
    )
    returned = f"return {error}" if empty_result else f"return result, {error}"
    return [
        f"{indent}switch {encoded_value} {{",
        f"{indent}case {allowed}:",
        f"{indent}default:",
        f"{indent}\t{returned}",
        f"{indent}}}",
    ]


def _render_method(
    wire_name: str,
    command: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> list[str]:
    if wire_name in _SPECIAL_METHODS:
        return []
    name = _go_name(wire_name)
    shape, arguments, params, params_may_error = _method_shape(
        wire_name,
        command,
        named_types,
    )
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
    if shape == "shaped":
        for field_name, field in _request_expr(command)["fields"].items():
            if (
                field["presence"] != "required"
                or _inline_constraint(field["type"]) is None
            ):
                continue
            argument = _lower_go_name(field_name)
            if field["nullable"]:
                lines.append(
                    f"\tif fieldValue, ok := {argument}.Get(); ok {{"
                )
                lines.extend(
                    _render_method_constraint_validation(
                        wire_name,
                        field_name,
                        field["type"],
                        "fieldValue",
                        "\t\t",
                        empty_result=empty,
                    )
                )
                lines.append("\t}")
            else:
                lines.extend(
                    _render_method_constraint_validation(
                        wire_name,
                        field_name,
                        field["type"],
                        argument,
                        "\t",
                        empty_result=empty,
                    )
                )
    if params_may_error:
        lines.extend(
            [
                f"\tparams, err := {params}",
                "\tif err != nil {",
                f'\t\terr = fmt.Errorf("%w: encode {wire_name} parameters: %v", '
                "ErrInvalidArgument, err)",
                "\t\t" + ("return err" if empty else "return result, err"),
                "\t}",
                f"\terr = c.requestGenerated(ctx, "
                f"commandMetadata[{_go_string(wire_name)}], "
                f"{_go_string(wire_name)}, params, "
                + ("nil)" if empty else "&result)"),
            ]
        )
    else:
        lines.append(
            f"\terr := c.requestGenerated(ctx, "
            f"commandMetadata[{_go_string(wire_name)}], "
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
    lines.extend(
        [
            "package raw",
            "",
            "import (",
            '\t"context"',
            '\t"encoding/json"',
            '\t"fmt"',
            ")",
            "",
        ]
    )
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
            "package raw",
            "",
            "import (",
            '\t"context"',
            '\t"encoding/json"',
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
            "package raw",
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


def _generated_object_models(
    document: Mapping[str, Any],
) -> list[tuple[str, Mapping[str, Any]]]:
    models: list[tuple[str, Mapping[str, Any]]] = []
    named_go_types = {_go_name(name) for name in document["types"]}
    for wire_name, expr in document["types"].items():
        name = _go_name(wire_name)
        if expr["kind"] == "object":
            models.append((name, expr))
        elif expr["kind"] == "tagged_union":
            for tag_value, variant in expr["variants"].items():
                if variant["kind"] == "object":
                    models.append((_variant_name(name, str(tag_value)), variant))
    for wire_name, command in document["commands"].items():
        request = _request_expr(command)
        models.append((_request_name(wire_name), request))
        result_name = _result_name(wire_name)
        if (
            result_name not in named_go_types
            and command["result"]["kind"] == "object"
        ):
            models.append((result_name, command["result"]))
        optional = {
            name: field
            for name, field in request["fields"].items()
            if field["presence"] == "optional"
        }
        if optional and wire_name not in _SPECIAL_METHODS:
            models.append(
                (
                    _options_name(wire_name),
                    {
                        "kind": "object",
                        "fields": optional,
                        "additional_properties": False,
                    },
                )
            )
    for wire_name, event in document["events"].items():
        payload = dict(event["payload"])
        payload["fields"] = {
            name: field
            for name, field in payload["fields"].items()
            if name != "event"
        }
        models.append((_event_name(wire_name), payload))
    return models


def _sample_json_value(
    expr: Mapping[str, Any],
    named_types: Mapping[str, Any],
    seen: frozenset[str] = frozenset(),
) -> Any:
    kind = expr["kind"]
    if kind == "scalar":
        name = expr["name"]
        if name == "string":
            return "value"
        if name == "boolean":
            return True
        if name in {"float32", "float64"}:
            return 1.5
        return 1
    if kind == "literal":
        return expr["value"]
    if kind == "enum":
        return expr["values"][0]
    if kind == "alias":
        return _sample_json_value(expr["target"], named_types, seen)
    if kind == "ref":
        name = expr["name"]
        if name in seen:
            raise ValueError(f"recursive Go presence test value through {name}")
        return _sample_json_value(
            named_types[name],
            named_types,
            seen | {name},
        )
    if kind == "array":
        return []
    if kind == "map":
        return {}
    if kind == "opaque_json":
        return {"value": True}
    if kind == "object":
        result: dict[str, Any] = {}
        for wire_name, field in expr["fields"].items():
            if field["presence"] != "required":
                continue
            if field["nullable"]:
                result[wire_name] = None
            else:
                result[wire_name] = _sample_json_value(
                    field["type"],
                    named_types,
                    seen,
                )
        return result
    if kind == "tagged_union":
        tag_value, variant = next(iter(expr["variants"].items()))
        result = _sample_json_value(variant, named_types, seen)
        if not isinstance(result, dict):
            result = {"value": result}
        result[expr["tag"]] = tag_value
        return result
    if kind == "untagged_union":
        return _sample_json_value(expr["variants"][0], named_types, seen)
    raise ValueError(f"unsupported Go presence test kind: {kind}")


def _presence_base_json(
    expr: Mapping[str, Any],
    named_types: Mapping[str, Any],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for wire_name, field in expr["fields"].items():
        if field["presence"] != "required":
            continue
        if field["nullable"]:
            result[wire_name] = None
        else:
            result[wire_name] = _sample_json_value(
                field["type"],
                named_types,
            )
    return result


def _resolved_constraint(
    expr: Mapping[str, Any],
    named_types: Mapping[str, Any],
    seen: frozenset[str] = frozenset(),
) -> Mapping[str, Any] | None:
    kind = expr["kind"]
    if kind in {"enum", "literal"}:
        return expr
    if kind == "alias":
        return _resolved_constraint(expr["target"], named_types, seen)
    if kind == "ref":
        name = expr["name"]
        if name in seen:
            return None
        return _resolved_constraint(
            named_types[name],
            named_types,
            seen | {name},
        )
    return None


def _invalid_constraint_value(expr: Mapping[str, Any]) -> Any:
    values = (
        [expr["value"]]
        if expr["kind"] == "literal"
        else list(expr["values"])
    )
    first = values[0]
    if isinstance(first, bool):
        candidate: Any = not first
        if candidate not in values:
            return candidate
        return "__cmux_invalid_boolean__"
    if isinstance(first, str):
        candidate = "__cmux_invalid__"
        while candidate in values:
            candidate += "_"
        return candidate
    if isinstance(first, int):
        candidate = max(value for value in values if isinstance(value, int)) + 1
        while candidate in values:
            candidate += 1
        return candidate
    if isinstance(first, float):
        candidate = max(float(value) for value in values) + 0.5
        while candidate in values:
            candidate += 0.5
        return candidate
    return "__cmux_invalid_null_literal__"


def _render_presence_tests(
    ir: SdkIR,
    document: Mapping[str, Any],
) -> str:
    lines = _header(ir)
    lines.extend(
        [
            "package raw",
            "",
            "import (",
            '\t"encoding/json"',
            '\t"reflect"',
            '\t"testing"',
            ")",
            "",
            "func assertGeneratedFieldJSON(",
            "\tt *testing.T,",
            "\tmodel any,",
            "\tfield string,",
            "\tpresent bool,",
            "\texpected string,",
            ") {",
            "\tt.Helper()",
            "\tencoded, err := json.Marshal(model)",
            "\tif err != nil {",
            "\t\tt.Fatal(err)",
            "\t}",
            "\tvar object map[string]json.RawMessage",
            "\tif err := json.Unmarshal(encoded, &object); err != nil {",
            "\t\tt.Fatal(err)",
            "\t}",
            "\traw, exists := object[field]",
            "\tif exists != present {",
            '\t\tt.Fatalf("%s presence = %t, want %t; JSON = %s", '
            "field, exists, present, encoded)",
            "\t}",
            "\tif !present {",
            "\t\treturn",
            "\t}",
            "\tvar got, want any",
            "\tif err := json.Unmarshal(raw, &got); err != nil {",
            "\t\tt.Fatal(err)",
            "\t}",
            "\tif err := json.Unmarshal([]byte(expected), &want); err != nil {",
            "\t\tt.Fatal(err)",
            "\t}",
            "\tif !reflect.DeepEqual(got, want) {",
            '\t\tt.Fatalf("%s = %s, want %s", field, raw, expected)',
            "\t}",
            "}",
            "",
            "func TestGeneratedSchemaPresenceRoundTrips(t *testing.T) {",
        ]
    )
    affected = 0
    optional_nullable = 0
    required_nullable = 0
    optional_nonnullable = 0
    for model_name, expr in _generated_object_models(document):
        base = _presence_base_json(expr, document["types"])
        for wire_name, field in expr["fields"].items():
            if not field["nullable"] and field["presence"] != "optional":
                continue
            affected += 1
            if field["nullable"] and field["presence"] == "optional":
                optional_nullable += 1
            elif field["nullable"]:
                required_nullable += 1
            else:
                optional_nonnullable += 1
            go_name = _go_name(wire_name)
            test_name = f"{model_name}.{go_name}"
            missing = dict(base)
            missing.pop(wire_name, None)
            missing_json = json.dumps(
                missing,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            null = dict(base)
            null[wire_name] = None
            null_json = json.dumps(
                null,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            sample = _sample_json_value(field["type"], document["types"])
            value = dict(base)
            value[wire_name] = sample
            value_json = json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            sample_json = json.dumps(
                sample,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            lines.extend(
                [
                    f"\tt.Run({_go_string(test_name)}, func(t *testing.T) {{",
                ]
            )
            if field["nullable"] and field["presence"] == "optional":
                lines.extend(
                    [
                        f"\t\tvar missing {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(missing_json)}), "
                        "&missing); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif !missing.{go_name}.IsAbsent() {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve absence")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, missing, "
                        f"{_go_string(wire_name)}, false, \"\")",
                        f"\t\tvar nullValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(null_json)}), "
                        "&nullValue); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif !nullValue.{go_name}.IsNull() {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve null")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, nullValue, "
                        f"{_go_string(wire_name)}, true, \"null\")",
                        f"\t\tvar presentValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(value_json)}), "
                        "&presentValue); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif _, ok := presentValue.{go_name}.Get(); !ok {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve a value")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, presentValue, "
                        f"{_go_string(wire_name)}, true, {_go_string(sample_json)})",
                    ]
                )
            elif field["nullable"]:
                lines.extend(
                    [
                        f"\t\tvar missing {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(missing_json)}), "
                        "&missing); err == nil {",
                        f'\t\t\tt.Fatal("missing required nullable field '
                        f'{wire_name} decoded successfully")',
                        "\t\t}",
                        f"\t\tvar nullValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(null_json)}), "
                        "&nullValue); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif !nullValue.{go_name}.IsSet() || "
                        f"!nullValue.{go_name}.IsNull() {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve required null")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, nullValue, "
                        f"{_go_string(wire_name)}, true, \"null\")",
                        f"\t\tvar presentValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(value_json)}), "
                        "&presentValue); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif _, ok := presentValue.{go_name}.Get(); !ok {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve a required value")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, presentValue, "
                        f"{_go_string(wire_name)}, true, {_go_string(sample_json)})",
                    ]
                )
            else:
                lines.extend(
                    [
                        f"\t\tvar missing {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(missing_json)}), "
                        "&missing); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif missing.{go_name} != nil {{",
                        f'\t\t\tt.Fatal("{go_name} did not preserve absence")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, missing, "
                        f"{_go_string(wire_name)}, false, \"\")",
                        f"\t\tvar nullValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(null_json)}), "
                        "&nullValue); err == nil {",
                        f'\t\t\tt.Fatal("non-nullable field {wire_name} accepted null")',
                        "\t\t}",
                        f"\t\tvar presentValue {model_name}",
                        f"\t\tif err := json.Unmarshal([]byte({_go_string(value_json)}), "
                        "&presentValue); err != nil {",
                        "\t\t\tt.Fatal(err)",
                        "\t\t}",
                        f"\t\tif presentValue.{go_name} == nil {{",
                        f'\t\t\tt.Fatal("{go_name} lost its value")',
                        "\t\t}",
                        f"\t\tassertGeneratedFieldJSON(t, presentValue, "
                        f"{_go_string(wire_name)}, true, {_go_string(sample_json)})",
                    ]
                )
            lines.extend(["\t})"])
    lines.extend(["}", "", "func TestGeneratedRequiredFieldsRejectOmission(t *testing.T) {"])
    required_fields = 0
    for model_name, expr in _generated_object_models(document):
        base = _presence_base_json(expr, document["types"])
        for wire_name, field in expr["fields"].items():
            if field["presence"] != "required":
                continue
            required_fields += 1
            missing = dict(base)
            missing.pop(wire_name, None)
            missing_json = json.dumps(
                missing,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            lines.extend(
                [
                    f"\tt.Run({_go_string(f'{model_name}.{_go_name(wire_name)}')}, func(t *testing.T) {{",
                    f"\t\tvar decoded {model_name}",
                    f"\t\tif err := json.Unmarshal([]byte({_go_string(missing_json)}), &decoded); err == nil {{",
                    f'\t\t\tt.Fatal("missing required field {wire_name} decoded successfully")',
                    "\t\t}",
                    "\t})",
                ]
            )
    lines.extend(
        [
            "}",
            "",
            "func TestGeneratedRequiredNonnullableFieldsRejectNull(t *testing.T) {",
        ]
    )
    required_nonnullable_fields = 0
    for model_name, expr in _generated_object_models(document):
        base = _presence_base_json(expr, document["types"])
        for wire_name, field in expr["fields"].items():
            if field["presence"] != "required" or field["nullable"]:
                continue
            required_nonnullable_fields += 1
            null = dict(base)
            null[wire_name] = None
            null_json = json.dumps(
                null,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            lines.extend(
                [
                    f"\tt.Run({_go_string(f'{model_name}.{_go_name(wire_name)}')}, func(t *testing.T) {{",
                    f"\t\tvar decoded {model_name}",
                    f"\t\tif err := json.Unmarshal([]byte({_go_string(null_json)}), &decoded); err == nil {{",
                    f'\t\t\tt.Fatal("required non-nullable field {wire_name} accepted null")',
                    "\t\t}",
                    "\t})",
                ]
            )
    lines.extend(
        [
            "}",
            "",
            "func TestGeneratedConstrainedFieldsRejectUnknownValues(t *testing.T) {",
        ]
    )
    constrained_fields = 0
    for model_name, expr in _generated_object_models(document):
        base = _presence_base_json(expr, document["types"])
        for wire_name, field in expr["fields"].items():
            constraint = _resolved_constraint(field["type"], document["types"])
            if constraint is None:
                continue
            constrained_fields += 1
            invalid = dict(base)
            invalid[wire_name] = _invalid_constraint_value(constraint)
            invalid_json = json.dumps(
                invalid,
                ensure_ascii=False,
                separators=(",", ":"),
            )
            lines.extend(
                [
                    f"\tt.Run({_go_string(f'{model_name}.{_go_name(wire_name)}')}, func(t *testing.T) {{",
                    f"\t\tvar decoded {model_name}",
                    f"\t\tif err := json.Unmarshal([]byte({_go_string(invalid_json)}), &decoded); err == nil {{",
                    f'\t\t\tt.Fatal("invalid constrained field {wire_name} decoded successfully")',
                    "\t\t}",
                    "\t})",
                ]
            )
    lines.extend(
        [
            "}",
            "",
            "func TestGeneratedConstrainedFieldsRejectUnknownValuesOnMarshal(t *testing.T) {",
        ]
    )
    encoded_constrained_fields = 0
    for model_name, expr in _generated_object_models(document):
        base = _presence_base_json(expr, document["types"])
        base_json = json.dumps(
            base,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        for wire_name, field in expr["fields"].items():
            constraint = _resolved_constraint(field["type"], document["types"])
            if constraint is None:
                continue
            invalid = _invalid_constraint_value(constraint)
            values = (
                [constraint["value"]]
                if constraint["kind"] == "literal"
                else list(constraint["values"])
            )
            if _underlying_literal_type(invalid) != _enum_base(values):
                continue
            encoded_constrained_fields += 1
            go_name = _go_name(wire_name)
            value_type = _field_value_type(
                model_name,
                wire_name,
                field,
            )
            converted = f"{value_type}({_go_literal(invalid)})"
            lines.extend(
                [
                    f"\tt.Run({_go_string(f'{model_name}.{go_name}')}, func(t *testing.T) {{",
                    f"\t\tvar decoded {model_name}",
                    f"\t\tif err := json.Unmarshal([]byte({_go_string(base_json)}), &decoded); err != nil {{",
                    "\t\t\tt.Fatal(err)",
                    "\t\t}",
                ]
            )
            if field["nullable"]:
                constructor = (
                    "Value"
                    if field["presence"] == "optional"
                    else "RequiredValue"
                )
                lines.append(
                    f"\t\tdecoded.{go_name} = {constructor}({converted})"
                )
            elif field["presence"] == "optional":
                lines.extend(
                    [
                        f"\t\tinvalidValue := {converted}",
                        f"\t\tdecoded.{go_name} = &invalidValue",
                    ]
                )
            else:
                lines.append(f"\t\tdecoded.{go_name} = {converted}")
            lines.extend(
                [
                    "\t\tif _, err := json.Marshal(decoded); err == nil {",
                    f'\t\t\tt.Fatal("invalid constrained field {wire_name} encoded successfully")',
                    "\t\t}",
                    "\t})",
                ]
            )
    lines.extend(
        [
            "}",
            "",
            "const (",
            f"\tgeneratedFieldShapeCount = {affected}",
            f"\tgeneratedOptionalNullableFieldCount = {optional_nullable}",
            f"\tgeneratedRequiredNullableFieldCount = {required_nullable}",
            f"\tgeneratedOptionalNonnullableFieldCount = {optional_nonnullable}",
            f"\tgeneratedRequiredFieldCount = {required_fields}",
            f"\tgeneratedRequiredNonnullableFieldCount = {required_nonnullable_fields}",
            f"\tgeneratedConstrainedFieldCount = {constrained_fields}",
            f"\tgeneratedEncodedConstrainedFieldCount = {encoded_constrained_fields}",
            ")",
        ]
    )
    return "\n".join(lines).rstrip() + "\n"


def emit(ir: SdkIR) -> Mapping[str | PurePosixPath, str | bytes]:
    document = _plain(ir.document)
    return {
        "generated_commands.go": _gofmt(_render_commands(ir, document)),
        "generated_events.go": _gofmt(_render_events(ir, document)),
        "generated_metadata.go": _gofmt(_render_metadata(ir, document)),
        "generated_presence_test.go": _gofmt(
            _render_presence_tests(ir, document)
        ),
        "generated_types.go": _gofmt(_render_types(ir, document)),
    }


EMITTER = Emitter(
    language="go",
    output_root=PurePosixPath("go/raw"),
    render=emit,
)
