"""Deterministic C++20 SDK emitter."""

from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import PurePosixPath
from typing import Any

from codegen.ir import SdkIR
from codegen.naming import pascal_case, snake_case
from codegen.writer import Emitter

CPP_RESERVED = frozenset(
    """
    alignas alignof and and_eq asm atomic_cancel atomic_commit atomic_noexcept
    auto bitand bitor bool break case catch char char8_t char16_t char32_t class
    compl concept const consteval constexpr constinit const_cast continue
    co_await co_return co_yield decltype default delete do double dynamic_cast
    else enum explicit export extern false float for friend goto if inline int
    long mutable namespace new noexcept not not_eq nullptr operator or or_eq
    private protected public reflexpr register reinterpret_cast requires return
    short signed sizeof static static_assert static_cast struct switch
    synchronized template this thread_local throw true try typedef typeid
    typename union unsigned using virtual void volatile wchar_t while xor xor_eq
    """.split()
)

CPP_PREDEFINED_MACROS = frozenset(
    """
    linux unix
    """.split()
)


def _cpp_field(value: str) -> str:
    result = snake_case(value) or "_"
    if result[0].isdigit():
        result = f"_{result}"
    if result in CPP_RESERVED or result in CPP_PREDEFINED_MACROS:
        result += "_"
    return result


def _cpp_type_name(value: str) -> str:
    result = pascal_case(value) or "Value"
    if result[0].isdigit():
        result = f"_{result}"
    return result


def _cpp_enum_value(value: Any) -> str:
    if isinstance(value, bool):
        source = "true" if value else "false"
    else:
        source = str(value)
    result = _cpp_field(source)
    if result == "_":
        result = "value"
    return result


def _quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _literal_json(value: Any) -> str:
    if value is None:
        return "Json(nullptr)"
    if value is True:
        return "Json(true)"
    if value is False:
        return "Json(false)"
    if isinstance(value, str):
        return f"Json(std::string({_quoted(value)}))"
    if isinstance(value, int):
        suffix = "ULL" if value >= 0 else "LL"
        cast = "std::uint64_t" if value >= 0 else "std::int64_t"
        return f"Json(static_cast<{cast}>({value}{suffix}))"
    return f"Json(static_cast<double>({value!r}))"


def _literal_cpp_type(value: Any) -> str:
    if value is None:
        return "Json"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, str):
        return "std::string"
    if isinstance(value, int):
        return "std::int64_t" if value < 0 else "std::uint64_t"
    return "double"


def _literal_cpp_value(value: Any) -> str:
    if value is None:
        return "Json(nullptr)"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return f"std::string({_quoted(value)})"
    if isinstance(value, int):
        suffix = "ULL" if value >= 0 else "LL"
        cast = "std::uint64_t" if value >= 0 else "std::int64_t"
        return f"static_cast<{cast}>({value}{suffix})"
    return f"static_cast<double>({value!r})"


class CppEmitter:
    def __init__(self, ir: SdkIR):
        self.ir = ir
        self.models: dict[str, Mapping[str, Any]] = {}
        self.expr_names: dict[int, str] = {}
        self.variant_tags: dict[str, tuple[str, Any]] = {}
        self.event_names: dict[str, str] = {}
        self.request_names: dict[str, str] = {}
        self.result_names: dict[str, str] = {}
        self._register_roots()
        self._discover_nested_models()
        self.components, self.component_for = self._ordered_components()

    def _unique_name(self, proposed: str) -> str:
        if proposed not in self.models:
            return proposed
        index = 2
        while f"{proposed}{index}" in self.models:
            index += 1
        return f"{proposed}{index}"

    def _register(
        self,
        proposed: str,
        expression: Mapping[str, Any],
        *,
        exact: bool = False,
    ) -> str:
        existing = self.expr_names.get(id(expression))
        if existing is not None:
            return existing
        name = proposed if exact else self._unique_name(proposed)
        if exact and name in self.models and self.models[name] is not expression:
            raise ValueError(f"duplicate C++ model name {name}")
        self.models[name] = expression
        self.expr_names[id(expression)] = name
        return name

    def _register_roots(self) -> None:
        for name, expression in self.ir.types.items():
            assert isinstance(expression, Mapping)
            self._register(_cpp_type_name(name), expression, exact=True)

        for wire_name, command in self.ir.commands.items():
            assert isinstance(command, Mapping)
            base = _cpp_type_name(wire_name)
            request = command["request"]
            assert isinstance(request, Mapping)
            self.request_names[wire_name] = self._register(
                f"{base}Request", request
            )
            result = command["result"]
            assert isinstance(result, Mapping)
            if result["kind"] == "ref":
                self.result_names[wire_name] = _cpp_type_name(str(result["name"]))
            else:
                self.result_names[wire_name] = self._register(
                    f"{base}Result", result
                )

        for wire_name, event in self.ir.events.items():
            assert isinstance(event, Mapping)
            payload = event["payload"]
            assert isinstance(payload, Mapping)
            model = self._register(f"{_cpp_type_name(wire_name)}Event", payload)
            self.event_names[wire_name] = model
            self.variant_tags[model] = ("event", wire_name)

    def _discover_nested_models(self) -> None:
        position = 0
        while position < len(self.models):
            name = tuple(self.models)[position]
            expression = self.models[name]
            self._discover_expression(name, expression)
            position += 1

    def _discover_expression(self, owner: str, expression: Mapping[str, Any]) -> None:
        kind = expression["kind"]
        if kind in {"alias"}:
            target = expression["target"]
            assert isinstance(target, Mapping)
            self._discover_child(f"{owner}Value", target)
        elif kind == "object":
            for wire_name, field in expression["fields"].items():
                assert isinstance(field, Mapping)
                field_type = field["type"]
                assert isinstance(field_type, Mapping)
                self._discover_child(f"{owner}{_cpp_type_name(wire_name)}", field_type)
        elif kind == "tagged_union":
            tag = str(expression["tag"])
            for variant, variant_type in expression["variants"].items():
                assert isinstance(variant_type, Mapping)
                model = self._register(
                    f"{owner}{_cpp_type_name(str(variant))}", variant_type
                )
                self.variant_tags[model] = (tag, variant)
        elif kind == "untagged_union":
            for index, variant in enumerate(expression["variants"], start=1):
                assert isinstance(variant, Mapping)
                self._discover_child(f"{owner}Variant{index}", variant)
        elif kind == "array":
            item = expression["items"]
            assert isinstance(item, Mapping)
            self._discover_child(f"{owner}Item", item)
        elif kind == "map":
            value = expression["values"]
            assert isinstance(value, Mapping)
            self._discover_child(f"{owner}Value", value)

    def _discover_child(self, proposed: str, expression: Mapping[str, Any]) -> None:
        if expression["kind"] in {
            "enum",
            "object",
            "tagged_union",
            "untagged_union",
            "opaque_json",
        }:
            self._register(proposed, expression)
            return
        kind = expression["kind"]
        if kind == "array":
            item = expression["items"]
            assert isinstance(item, Mapping)
            self._discover_child(f"{proposed}Item", item)
        elif kind == "map":
            value = expression["values"]
            assert isinstance(value, Mapping)
            self._discover_child(f"{proposed}Value", value)

    def _dependencies(
        self, owner: str, expression: Mapping[str, Any]
    ) -> set[str]:
        result: set[str] = set()

        def visit(value: Mapping[str, Any], *, root: bool = False) -> None:
            registered = self.expr_names.get(id(value))
            if not root and registered is not None and registered != owner:
                result.add(registered)
                return
            kind = value["kind"]
            if kind == "ref":
                result.add(_cpp_type_name(str(value["name"])))
            elif kind == "alias":
                target = value["target"]
                assert isinstance(target, Mapping)
                visit(target)
            elif kind == "object":
                for field in value["fields"].values():
                    field_type = field["type"]
                    assert isinstance(field_type, Mapping)
                    visit(field_type)
            elif kind == "tagged_union":
                for variant in value["variants"].values():
                    assert isinstance(variant, Mapping)
                    visit(variant)
            elif kind == "untagged_union":
                for variant in value["variants"]:
                    assert isinstance(variant, Mapping)
                    visit(variant)
            elif kind == "array":
                item = value["items"]
                assert isinstance(item, Mapping)
                visit(item)
            elif kind == "map":
                item = value["values"]
                assert isinstance(item, Mapping)
                visit(item)

        visit(expression, root=True)
        return {name for name in result if name in self.models and name != owner}

    def _ordered_components(self) -> tuple[list[list[str]], dict[str, int]]:
        graph = {
            name: self._dependencies(name, expression)
            for name, expression in self.models.items()
        }
        index = 0
        stack: list[str] = []
        indices: dict[str, int] = {}
        low: dict[str, int] = {}
        on_stack: set[str] = set()
        raw_components: list[list[str]] = []

        def strong_connect(node: str) -> None:
            nonlocal index
            indices[node] = index
            low[node] = index
            index += 1
            stack.append(node)
            on_stack.add(node)
            for dependency in sorted(graph[node]):
                if dependency not in indices:
                    strong_connect(dependency)
                    low[node] = min(low[node], low[dependency])
                elif dependency in on_stack:
                    low[node] = min(low[node], indices[dependency])
            if low[node] == indices[node]:
                component: list[str] = []
                while True:
                    member = stack.pop()
                    on_stack.remove(member)
                    component.append(member)
                    if member == node:
                        break
                raw_components.append(component)

        for model in sorted(graph):
            if model not in indices:
                strong_connect(model)

        raw_for = {
            model: component
            for component, members in enumerate(raw_components)
            for model in members
        }
        component_dependencies = {
            component: {
                raw_for[dependency]
                for member in members
                for dependency in graph[member]
                if raw_for[dependency] != component
            }
            for component, members in enumerate(raw_components)
        }
        ordered_ids: list[int] = []
        seen: set[int] = set()

        def order(component: int) -> None:
            if component in seen:
                return
            seen.add(component)
            for dependency in sorted(component_dependencies[component]):
                order(dependency)
            ordered_ids.append(component)

        for component in range(len(raw_components)):
            order(component)

        components: list[list[str]] = []
        component_for: dict[str, int] = {}
        for new_id, raw_id in enumerate(ordered_ids):
            members = sorted(
                raw_components[raw_id],
                key=lambda name: (
                    self.models[name]["kind"] == "tagged_union",
                    self.models[name]["kind"] == "untagged_union",
                    name,
                ),
            )
            components.append(members)
            for member in members:
                component_for[member] = new_id
        return components, component_for

    def _cpp_type(
        self,
        expression: Mapping[str, Any],
        owner: str,
        *,
        root: bool = False,
    ) -> str:
        registered = self.expr_names.get(id(expression))
        if not root and registered is not None and registered != owner:
            return registered
        kind = expression["kind"]
        if kind == "scalar":
            return {
                "string": "std::string",
                "boolean": "bool",
                "int32": "std::int32_t",
                "uint16": "std::uint16_t",
                "uint32": "std::uint32_t",
                "int64": "std::int64_t",
                "uint64": "std::uint64_t",
                "float32": "float",
                "float64": "double",
            }[str(expression["name"])]
        if kind == "literal":
            return _literal_cpp_type(expression["value"])
        if kind == "ref":
            target = _cpp_type_name(str(expression["name"]))
            if self.component_for.get(target) == self.component_for.get(owner):
                return f"std::shared_ptr<{target}>"
            return target
        if kind == "array":
            item = expression["items"]
            assert isinstance(item, Mapping)
            return f"std::vector<{self._cpp_type(item, owner)}>"
        if kind == "map":
            value = expression["values"]
            assert isinstance(value, Mapping)
            return (
                "std::map<std::string, "
                f"{self._cpp_type(value, owner)}, std::less<>>"
            )
        if kind == "opaque_json":
            return "Json"
        if kind in {"enum", "object", "tagged_union", "untagged_union"}:
            if registered is None:
                raise ValueError(f"unnamed inline C++ type in {owner}")
            return registered
        if kind == "alias":
            target = expression["target"]
            assert isinstance(target, Mapping)
            return self._cpp_type(target, owner)
        raise ValueError(f"unsupported C++ type kind {kind!r}")

    def _field_type(
        self, owner: str, field: Mapping[str, Any]
    ) -> str:
        expression = field["type"]
        assert isinstance(expression, Mapping)
        base = self._cpp_type(expression, owner)
        optional = field["presence"] == "optional"
        nullable = bool(field["nullable"])
        if optional and nullable:
            return f"Field<{base}>"
        if optional or nullable:
            return f"std::optional<{base}>"
        return base

    def _model_definition(self, name: str, expression: Mapping[str, Any]) -> list[str]:
        kind = expression["kind"]
        if kind == "enum":
            values = list(expression["values"])
            used: set[str] = set()
            entries: list[str] = []
            for value in values:
                entry = _cpp_enum_value(value)
                while entry in used:
                    entry += "_"
                used.add(entry)
                entries.append(f"    {entry},")
            return [f"enum class {name} {{", *entries, "};"]

        if kind == "object":
            lines = [f"struct {name} {{"]
            tag = self.variant_tags.get(name)
            for wire_name, field in expression["fields"].items():
                assert isinstance(field, Mapping)
                field_expression = field["type"]
                assert isinstance(field_expression, Mapping)
                if (
                    field_expression["kind"] == "literal"
                    and field["presence"] == "required"
                    and not field["nullable"]
                ):
                    continue
                if tag and wire_name == tag[0]:
                    continue
                lines.append(
                    f"    {self._field_type(name, field)} {_cpp_field(wire_name)}{{}};"
                )
            if expression["additional_properties"]:
                lines.append("    Json::Object additional_properties{};")
            lines.append(f"    friend bool operator==(const {name}&, const {name}&) = default;")
            lines.append("};")
            return lines

        if kind in {"tagged_union", "untagged_union"}:
            variants: list[str] = []
            source = (
                expression["variants"].values()
                if kind == "tagged_union"
                else expression["variants"]
            )
            for variant in source:
                assert isinstance(variant, Mapping)
                variants.append(self._cpp_type(variant, name))
            return [
                f"struct {name} {{",
                f"    using Variant = std::variant<{', '.join(variants)}>;",
                "    Variant value{};",
                f"    friend bool operator==(const {name}&, const {name}&) = default;",
                "};",
            ]

        if kind == "opaque_json":
            underlying = "Json"
        elif kind == "alias":
            target = expression["target"]
            assert isinstance(target, Mapping)
            underlying = self._cpp_type(target, name)
        elif kind in {"scalar", "literal", "array", "map", "ref"}:
            underlying = self._cpp_type(expression, name, root=True)
        else:
            raise ValueError(f"cannot define C++ model {name} with kind {kind}")
        return [
            f"struct {name} {{",
            f"    {underlying} value{{}};",
            f"    friend bool operator==(const {name}&, const {name}&) = default;",
            "};",
        ]

    def models_header(self) -> str:
        lines = [
            "#pragma once",
            "",
            "#include <cstdint>",
            "#include <map>",
            "#include <memory>",
            "#include <optional>",
            "#include <string>",
            "#include <string_view>",
            "#include <variant>",
            "#include <vector>",
            "",
            '#include "cmux/raw/codec.hpp"',
            "",
            "namespace cmux::raw {",
            "",
            f"inline constexpr std::uint32_t kMuxProtocolVersion = {self.ir.mux_protocol}U;",
            f'inline constexpr std::string_view kProtocolIrSha256 = "{self.ir.ir_sha256}";',
            "",
        ]
        for name, expression in self.models.items():
            declaration = "enum class" if expression["kind"] == "enum" else "struct"
            lines.append(f"{declaration} {name};")
        lines.append("")
        for component in self.components:
            for name in component:
                lines.extend(self._model_definition(name, self.models[name]))
                lines.append("")
        for name in self.models:
            lines.extend(
                [
                    "template <>",
                    f"struct Codec<{name}> {{",
                    f"    static Result<Json> encode(const {name}& value);",
                    f"    static Result<{name}> decode(const Json& value);",
                    "};",
                    "",
                ]
            )
        lines.extend(["}  // namespace cmux::raw", ""])
        return "\n".join(lines)

    def events_header(self) -> str:
        event_types = [self.event_names[name] for name in self.ir.events]
        lines = [
            "#pragma once",
            "",
            "#include <span>",
            "#include <string>",
            "#include <string_view>",
            "#include <variant>",
            "",
            '#include "cmux/raw/generated/models.hpp"',
            '#include "cmux/raw/stream.hpp"',
            "",
            "namespace cmux::raw {",
            "",
            "struct UnknownEvent {",
            "    std::string name;",
            "    Json raw;",
            "    friend bool operator==(const UnknownEvent&, const UnknownEvent&) = default;",
            "};",
            "",
            "struct Event {",
            f"    using Variant = std::variant<{', '.join(event_types)}, UnknownEvent>;",
            "    Variant value;",
            "    Json raw;",
            "    [[nodiscard]] std::string_view name() const noexcept;",
            "};",
            "",
            "template <>",
            "struct Codec<Event> {",
            "    static Result<Json> encode(const Event& value);",
            "    static Result<Event> decode(const Json& value);",
            "};",
            "",
            "using EventStream = Stream<Event>;",
            "using SubscriptionStream = EventStream;",
            "using DeltaStream = EventStream;",
            "using ByteStream = EventStream;",
            "using RenderStream = EventStream;",
            "using BrowserStream = EventStream;",
            "",
            "struct EventMetadata {",
            "    std::string_view name;",
            "    std::uint32_t since;",
            "    std::string_view capability;",
            "    std::string_view streams;",
            "    std::string_view emission;",
            "};",
            "",
            "[[nodiscard]] std::span<const EventMetadata> event_metadata() noexcept;",
            "",
            "}  // namespace cmux::raw",
            "",
        ]
        return "\n".join(lines)

    def _request_has_required_fields(self, request_name: str) -> bool:
        request = self.models[request_name]
        for field in request["fields"].values():
            expression = field["type"]
            if expression["kind"] == "literal":
                continue
            if field["presence"] == "required":
                return True
        return False

    def commands_header(self) -> str:
        lines = [
            "#pragma once",
            "",
            "#include <cstdint>",
            "#include <span>",
            "#include <string_view>",
            "#include <utility>",
            "",
            '#include "cmux/raw/client_core.hpp"',
            '#include "cmux/raw/generated/events.hpp"',
            "",
            "namespace cmux::raw {",
            "",
            "struct CommandFieldRequirement {",
            "    std::string_view name;",
            "    std::uint32_t since;",
            "    std::string_view capability;",
            "};",
            "",
            "struct CommandMetadata {",
            "    std::string_view name;",
            "    std::string_view authority;",
            "    std::uint32_t since;",
            "    std::string_view capability;",
            "    bool streaming;",
            "    std::string_view stream_kind;",
            "    std::string_view terminal_event;",
            "    std::span<const CommandFieldRequirement> field_requirements;",
            "};",
            "",
            "[[nodiscard]] std::span<const CommandMetadata> command_metadata() noexcept;",
            "",
            "class Client {",
            "public:",
            "    Client(const Client&) = delete;",
            "    Client& operator=(const Client&) = delete;",
            "    Client(Client&&) noexcept = default;",
            "    Client& operator=(Client&&) noexcept = default;",
            "    ~Client() = default;",
            "",
            "    [[nodiscard]] static Result<Client> connect(ClientOptions options = {});",
            "    void close() noexcept { core_.close(); }",
            "    [[nodiscard]] bool closed() const noexcept { return core_.closed(); }",
            "",
        ]
        for wire_name, command in self.ir.commands.items():
            request = self.request_names[wire_name]
            result = self.result_names[wire_name]
            method = _cpp_field(wire_name)
            default_request = " = {}" if not self._request_has_required_fields(request) else ""
            if command["stream"] is None:
                lines.append(
                    f"    [[nodiscard]] Result<{result}> {method}("
                    f"const {request}& request{default_request}, RequestOptions options = {{}});"
                )
            else:
                lines.append(
                    f"    [[nodiscard]] Result<EventStream> {method}("
                    f"const {request}& request{default_request}, RequestOptions options = {{}});"
                )
        if "subscribe" in self.request_names:
            request = self.request_names["subscribe"]
            lines.extend(
                [
                    "",
                    "    [[nodiscard]] Result<DeltaStream> subscribe_deltas(",
                    f"        const {request}& request = {{}}, RequestOptions options = {{}});",
                ]
            )
        if "attach-surface" in self.request_names:
            request = self.request_names["attach-surface"]
            lines.extend(
                [
                    "    [[nodiscard]] Result<ByteStream> attach_bytes(",
                    f"        const {request}& request, RequestOptions options = {{}});",
                    "    [[nodiscard]] Result<RenderStream> attach_render(",
                    f"        const {request}& request, RequestOptions options = {{}});",
                    "    [[nodiscard]] Result<BrowserStream> attach_browser(",
                    f"        const {request}& request, RequestOptions options = {{}});",
                ]
            )
        lines.extend(
            [
                "",
                "private:",
                "    explicit Client(detail::ClientCore core) : core_(std::move(core)) {}",
                "    [[nodiscard]] Result<EventStream> open_event_stream(",
                "        std::string_view command, Json::Object parameters,",
                "        std::string terminal_event, RequestOptions options);",
                "    detail::ClientCore core_;",
                "};",
                "",
                "}  // namespace cmux::raw",
                "",
            ]
        )
        return "\n".join(lines)

    def _decode_field_lines(
        self,
        owner: str,
        wire_name: str,
        field: Mapping[str, Any],
    ) -> list[str]:
        expression = field["type"]
        assert isinstance(expression, Mapping)
        member = _cpp_field(wire_name)
        aliases = [str(value) for value in field.get("aliases", ())]
        lines = [f'    const Json* field_{member} = value.find("{wire_name}");']
        for alias in aliases:
            lines.extend(
                [
                    f"    if (!field_{member}) {{",
                    f'        field_{member} = value.find("{alias}");',
                    "    }",
                ]
            )
        if expression["kind"] == "literal":
            expected = _literal_json(expression["value"])
            literal_value = _literal_cpp_value(expression["value"])
            optional = field["presence"] == "optional"
            nullable = bool(field["nullable"])
            lines.extend(
                [
                    *(
                        [
                            f"    if (!field_{member}) {{",
                            f'        return make_error(ErrorCode::decode, "missing required field \'{wire_name}\'");',
                            "    }",
                        ]
                        if not optional
                        else []
                    ),
                    f"    if (field_{member}) {{",
                ]
            )
            if nullable:
                lines.extend(
                    [
                        f"        if (field_{member}->is_null()) {{",
                        *(
                            [f"            result.{member} = Field<{_literal_cpp_type(expression['value'])}>::null();"]
                            if optional
                            else [f"            result.{member}.reset();"]
                        ),
                        "        } else {",
                        f"            if (*field_{member} != {expected}) {{",
                        f'                return make_error(ErrorCode::decode, "field \'{wire_name}\' has the wrong literal value");',
                        "            }",
                        *(
                            [
                                f"            result.{member} = Field<{_literal_cpp_type(expression['value'])}>({literal_value});"
                            ]
                            if optional
                            else [f"            result.{member} = {literal_value};"]
                        ),
                        "        }",
                    ]
                )
            else:
                lines.extend(
                    [
                        f"        if (*field_{member} != {expected}) {{",
                        f'            return make_error(ErrorCode::decode, "field \'{wire_name}\' has the wrong literal value");',
                        "        }",
                    ]
                )
                if optional:
                    lines.append(f"        result.{member} = {literal_value};")
            lines.append("    }")
            return lines

        base = self._cpp_type(expression, owner)
        optional = field["presence"] == "optional"
        nullable = bool(field["nullable"])
        if not optional:
            lines.extend(
                [
                    f"    if (!field_{member}) {{",
                    f'        return make_error(ErrorCode::decode, "missing required field \'{wire_name}\'");',
                    "    }",
                ]
            )
        lines.append(f"    if (field_{member}) {{")
        if optional and nullable:
            lines.extend(
                [
                    f"        if (field_{member}->is_null()) {{",
                    f"            result.{member} = Field<{base}>::null();",
                    "        } else {",
                    f"            auto decoded = decode_value<{base}>(*field_{member});",
                    "            if (!decoded) return std::move(decoded).error();",
                    f"            result.{member} = Field<{base}>(std::move(decoded).value());",
                    "        }",
                ]
            )
        elif nullable:
            lines.extend(
                [
                    f"        if (field_{member}->is_null()) {{",
                    f"            result.{member}.reset();",
                    "        } else {",
                    f"            auto decoded = decode_value<{base}>(*field_{member});",
                    "            if (!decoded) return std::move(decoded).error();",
                    f"            result.{member} = std::move(decoded).value();",
                    "        }",
                ]
            )
        else:
            lines.extend(
                [
                    f"        auto decoded = decode_value<{base}>(*field_{member});",
                    "        if (!decoded) return std::move(decoded).error();",
                    f"        result.{member} = std::move(decoded).value();",
                ]
            )
        lines.append("    }")
        return lines

    def _object_codec(self, name: str, expression: Mapping[str, Any]) -> list[str]:
        tag = self.variant_tags.get(name)
        lines = [
            f"Result<Json> Codec<{name}>::encode(const {name}& value) {{",
            "    (void)value;",
            "    Json::Object object;",
        ]
        if tag:
            lines.append(
                f'    object.emplace("{tag[0]}", {_literal_json(tag[1])});'
            )
        for wire_name, field in expression["fields"].items():
            assert isinstance(field, Mapping)
            field_expression = field["type"]
            assert isinstance(field_expression, Mapping)
            if tag and wire_name == tag[0]:
                continue
            member = _cpp_field(wire_name)
            if field_expression["kind"] == "literal":
                expected = _literal_json(field_expression["value"])
                optional = field["presence"] == "optional"
                nullable = bool(field["nullable"])
                if not optional and not nullable:
                    lines.append(f'    object.emplace("{wire_name}", {expected});')
                elif optional and nullable:
                    lines.extend(
                        [
                            f"    if (!value.{member}.is_absent()) {{",
                            f"        if (value.{member}.is_null()) {{",
                            f'            object.emplace("{wire_name}", Json(nullptr));',
                            "        } else {",
                            f"            auto encoded = encode_value(value.{member}.value());",
                            "            if (!encoded) return std::move(encoded).error();",
                            f"            if (encoded.value() != {expected}) {{",
                            f'                return make_error(ErrorCode::invalid_argument, "field \'{wire_name}\' has the wrong literal value");',
                            "            }",
                            f'            object.emplace("{wire_name}", std::move(encoded).value());',
                            "        }",
                            "    }",
                        ]
                    )
                elif optional:
                    lines.extend(
                        [
                            f"    if (value.{member}) {{",
                            f"        auto encoded = encode_value(*value.{member});",
                            "        if (!encoded) return std::move(encoded).error();",
                            f"        if (encoded.value() != {expected}) {{",
                            f'            return make_error(ErrorCode::invalid_argument, "field \'{wire_name}\' has the wrong literal value");',
                            "        }",
                            f'        object.emplace("{wire_name}", std::move(encoded).value());',
                            "    }",
                        ]
                    )
                else:
                    lines.extend(
                        [
                            f"    if (value.{member}) {{",
                            f"        auto encoded = encode_value(*value.{member});",
                            "        if (!encoded) return std::move(encoded).error();",
                            f"        if (encoded.value() != {expected}) {{",
                            f'            return make_error(ErrorCode::invalid_argument, "field \'{wire_name}\' has the wrong literal value");',
                            "        }",
                            f'        object.emplace("{wire_name}", std::move(encoded).value());',
                            "    } else {",
                            f'        object.emplace("{wire_name}", Json(nullptr));',
                            "    }",
                        ]
                    )
                continue
            optional = field["presence"] == "optional"
            nullable = bool(field["nullable"])
            if optional and nullable:
                lines.extend(
                    [
                        f"    if (!value.{member}.is_absent()) {{",
                        f"        auto encoded = encode_value(value.{member});",
                        "        if (!encoded) return std::move(encoded).error();",
                        f'        object.emplace("{wire_name}", std::move(encoded).value());',
                        "    }",
                    ]
                )
            elif optional:
                lines.extend(
                    [
                        f"    if (value.{member}) {{",
                        f"        auto encoded = encode_value(*value.{member});",
                        "        if (!encoded) return std::move(encoded).error();",
                        f'        object.emplace("{wire_name}", std::move(encoded).value());',
                        "    }",
                    ]
                )
            elif nullable:
                lines.extend(
                    [
                        f"    if (value.{member}) {{",
                        f"        auto encoded = encode_value(*value.{member});",
                        "        if (!encoded) return std::move(encoded).error();",
                        f'        object.emplace("{wire_name}", std::move(encoded).value());',
                        "    } else {",
                        f'        object.emplace("{wire_name}", Json(nullptr));',
                        "    }",
                    ]
                )
            else:
                lines.extend(
                    [
                        f"    auto encoded_{member} = encode_value(value.{member});",
                        f"    if (!encoded_{member}) return std::move(encoded_{member}).error();",
                        f'    object.emplace("{wire_name}", std::move(encoded_{member}).value());',
                    ]
                )
        if expression["additional_properties"]:
            lines.extend(
                [
                    "    for (const auto& [key, item] : value.additional_properties) {",
                    "        object.try_emplace(key, item);",
                    "    }",
                ]
            )
        lines.extend(["    return Json(std::move(object));", "}", ""])

        lines.extend(
            [
                f"Result<{name}> Codec<{name}>::decode(const Json& value) {{",
                "    auto source = value.as_object();",
                "    if (!source) return std::move(source).error();",
                f"    {name} result{{}};",
            ]
        )
        for wire_name, field in expression["fields"].items():
            assert isinstance(field, Mapping)
            if tag and wire_name == tag[0]:
                continue
            lines.extend(self._decode_field_lines(name, wire_name, field))
        if tag:
            synthetic_field = {
                "type": {"kind": "literal", "value": tag[1]},
                "presence": "required",
                "nullable": False,
            }
            lines.extend(self._decode_field_lines(name, tag[0], synthetic_field))
        if expression["additional_properties"]:
            known = {
                str(wire_name)
                for wire_name in expression["fields"]
            }
            if tag:
                known.add(tag[0])
            for field in expression["fields"].values():
                known.update(str(alias) for alias in field.get("aliases", ()))
            condition = " && ".join(f'key != "{key}"' for key in sorted(known)) or "true"
            lines.extend(
                [
                    "    for (const auto& [key, item] : *source.value()) {",
                    f"        if ({condition}) result.additional_properties.emplace(key, item);",
                    "    }",
                ]
            )
        lines.extend(["    return result;", "}", ""])
        return lines

    def _model_codec(self, name: str, expression: Mapping[str, Any]) -> list[str]:
        kind = expression["kind"]
        if kind == "object":
            return self._object_codec(name, expression)
        if kind == "enum":
            lines = [
                f"Result<Json> Codec<{name}>::encode(const {name}& value) {{",
                "    switch (value) {",
            ]
            for value in expression["values"]:
                lines.append(
                    f"        case {name}::{_cpp_enum_value(value)}: "
                    f"return {_literal_json(value)};"
                )
            lines.extend(
                [
                    "    }",
                    '    return make_error(ErrorCode::invalid_argument, "invalid enum value");',
                    "}",
                    "",
                    f"Result<{name}> Codec<{name}>::decode(const Json& value) {{",
                ]
            )
            for value in expression["values"]:
                lines.append(
                    f"    if (value == {_literal_json(value)}) "
                    f"return {name}::{_cpp_enum_value(value)};"
                )
            lines.extend(
                [
                    f'    return make_error(ErrorCode::decode, "unknown {name} value");',
                    "}",
                    "",
                ]
            )
            return lines
        if kind == "tagged_union":
            tag = str(expression["tag"])
            lines = [
                f"Result<Json> Codec<{name}>::encode(const {name}& value) {{",
                "    return encode_value(value.value);",
                "}",
                "",
                f"Result<{name}> Codec<{name}>::decode(const Json& value) {{",
                f'    auto tag = require_string(value, "{tag}");',
                "    if (!tag) return std::move(tag).error();",
            ]
            for variant, variant_type in expression["variants"].items():
                assert isinstance(variant_type, Mapping)
                variant_cpp = self._cpp_type(variant_type, name)
                lines.extend(
                    [
                        f'    if (tag.value() == "{variant}") {{',
                        f"        auto decoded = decode_value<{variant_cpp}>(value);",
                        "        if (!decoded) return std::move(decoded).error();",
                        f"        return {name}{{{name}::Variant(std::move(decoded).value())}};",
                        "    }",
                    ]
                )
            lines.extend(
                [
                    f'    return make_error(ErrorCode::decode, "unknown {name} tag");',
                    "}",
                    "",
                ]
            )
            return lines
        if kind == "untagged_union":
            variants = []
            for variant in expression["variants"]:
                assert isinstance(variant, Mapping)
                variants.append(self._cpp_type(variant, name))
            lines = [
                f"Result<Json> Codec<{name}>::encode(const {name}& value) {{",
                "    return encode_value(value.value);",
                "}",
                "",
                f"Result<{name}> Codec<{name}>::decode(const Json& value) {{",
            ]
            for variant in variants:
                lines.extend(
                    [
                        f"    if (auto decoded = decode_value<{variant}>(value); decoded) {{",
                        f"        return {name}{{{name}::Variant(std::move(decoded).value())}};",
                        "    }",
                    ]
                )
            lines.extend(
                [
                    f'    return make_error(ErrorCode::decode, "value did not match any {name} variant");',
                    "}",
                    "",
                ]
            )
            return lines
        if kind == "opaque_json":
            underlying = "Json"
        elif kind == "alias":
            target = expression["target"]
            assert isinstance(target, Mapping)
            underlying = self._cpp_type(target, name)
        else:
            underlying = self._cpp_type(expression, name, root=True)
        return [
            f"Result<Json> Codec<{name}>::encode(const {name}& value) {{",
            "    return encode_value(value.value);",
            "}",
            "",
            f"Result<{name}> Codec<{name}>::decode(const Json& value) {{",
            f"    auto decoded = decode_value<{underlying}>(value);",
            "    if (!decoded) return std::move(decoded).error();",
            f"    return {name}{{std::move(decoded).value()}};",
            "}",
            "",
        ]

    def _command_method(self, wire_name: str, command: Mapping[str, Any]) -> list[str]:
        request = self.request_names[wire_name]
        result = self.result_names[wire_name]
        method = _cpp_field(wire_name)
        if command["stream"] is None:
            return [
                f"Result<{result}> Client::{method}(",
                f"    const {request}& request, RequestOptions options) {{",
                "    auto encoded = encode_value(request);",
                "    if (!encoded) return std::move(encoded).error();",
                "    auto parameters = encoded.value().as_object();",
                "    if (!parameters) return std::move(parameters).error();",
                f'    auto response = core_.request("{wire_name}", *parameters.value(), options.timeout);',
                "    if (!response) return std::move(response).error();",
                f"    return decode_value<{result}>(response.value());",
                "}",
                "",
            ]
        stream = command["stream"]
        assert isinstance(stream, Mapping)
        terminal = stream["terminal_event"]
        terminal_text = "" if terminal is None else str(terminal)
        return [
            f"Result<EventStream> Client::{method}(",
            f"    const {request}& request, RequestOptions options) {{",
            "    auto encoded = encode_value(request);",
            "    if (!encoded) return std::move(encoded).error();",
            "    auto parameters = encoded.value().as_object();",
            "    if (!parameters) return std::move(parameters).error();",
            f'    return open_event_stream("{wire_name}", *parameters.value(), '
            f'"{terminal_text}", options);',
            "}",
            "",
        ]

    def source(self) -> str:
        lines = [
            "// Generated from cmux-tui/spec/sdk-schema.json. Do not edit.",
            '#include "cmux/raw/generated/commands.hpp"',
            "",
            "#include <array>",
            "#include <utility>",
            "",
            "namespace cmux::raw {",
            "",
        ]
        for name in self.models:
            lines.extend(self._model_codec(name, self.models[name]))

        lines.extend(
            [
                "std::string_view Event::name() const noexcept {",
                "    if (const auto* unknown = std::get_if<UnknownEvent>(&value)) {",
                "        return unknown->name;",
                "    }",
                '    const Json* event_name = raw.find("event");',
                "    if (!event_name) return {};",
                "    auto decoded = event_name->as_string();",
                "    return decoded ? decoded.value() : std::string_view{};",
                "}",
                "",
                "Result<Json> Codec<Event>::encode(const Event& value) {",
                "    if (const auto* unknown = std::get_if<UnknownEvent>(&value.value)) {",
                "        return unknown->raw;",
                "    }",
                "    return std::visit(",
                "        [](const auto& event) -> Result<Json> {",
                "            using T = std::decay_t<decltype(event)>;",
                "            if constexpr (std::is_same_v<T, UnknownEvent>) return event.raw;",
                "            else return encode_value(event);",
                "        },",
                "        value.value);",
                "}",
                "",
                "Result<Event> Codec<Event>::decode(const Json& value) {",
                '    auto name = require_string(value, "event");',
                "    if (!name) return std::move(name).error();",
            ]
        )
        for wire_name, model in self.event_names.items():
            lines.extend(
                [
                    f'    if (name.value() == "{wire_name}") {{',
                    f"        auto decoded = decode_value<{model}>(value);",
                    "        if (!decoded) return std::move(decoded).error();",
                    "        return Event{Event::Variant(std::move(decoded).value()), value};",
                    "    }",
                ]
            )
        lines.extend(
            [
                "    return Event{",
                "        Event::Variant(UnknownEvent{std::move(name).value(), value}), value};",
                "}",
                "",
                "namespace {",
            ]
        )
        field_requirement_arrays: dict[str, str] = {}
        for index, (wire_name, command) in enumerate(self.ir.commands.items()):
            request = command["request"]
            assert isinstance(request, Mapping)
            requirements = [
                (field_name, field)
                for field_name, field in request["fields"].items()
                if "since" in field or "capability" in field
            ]
            if not requirements:
                continue
            array_name = f"kCommand{index}FieldRequirements"
            field_requirement_arrays[wire_name] = array_name
            lines.append(
                f"constexpr std::array<CommandFieldRequirement, {len(requirements)}> "
                f"{array_name}{{{{"
            )
            for field_name, field in requirements:
                since = int(field.get("since", 0))
                capability = field.get("capability")
                cap = "" if capability is None else str(capability)
                lines.append(
                    f"    {{{_quoted(str(field_name))}, {since}U, {_quoted(cap)}}},"
                )
            lines.append("}};")
        lines.append(
            f"constexpr std::array<CommandMetadata, {len(self.ir.commands)}> kCommands{{{{"
        )
        for wire_name, command in self.ir.commands.items():
            capability = command["capability"]
            cap = "" if capability is None else str(capability)
            streaming = "true" if command["stream"] is not None else "false"
            stream = command["stream"]
            if stream is None:
                stream_kind = ""
                terminal_event = ""
            else:
                assert isinstance(stream, Mapping)
                stream_kind = str(stream["kind"])
                terminal = stream["terminal_event"]
                terminal_event = "" if terminal is None else str(terminal)
            field_requirements = field_requirement_arrays.get(wire_name)
            field_span = (
                "std::span<const CommandFieldRequirement>{}"
                if field_requirements is None
                else f"std::span<const CommandFieldRequirement>({field_requirements})"
            )
            lines.append(
                f'    {{"{wire_name}", "{command["authority"]}", '
                f'{command["since"]}U, "{cap}", {streaming}, '
                f'"{stream_kind}", "{terminal_event}", {field_span}}},'
            )
        lines.extend(
            [
                "}};",
                f"constexpr std::array<EventMetadata, {len(self.ir.events)}> kEvents{{{{",
            ]
        )
        for wire_name, event in self.ir.events.items():
            capability = event["capability"]
            cap = "" if capability is None else str(capability)
            streams = ",".join(str(value) for value in event["streams"])
            lines.append(
                f'    {{"{wire_name}", {event["since"]}U, "{cap}", '
                f'"{streams}", "{event["emission"]}"}},'
            )
        lines.extend(
            [
                "}};",
                "}  // namespace",
                "",
                "std::span<const CommandMetadata> command_metadata() noexcept { return kCommands; }",
                "std::span<const EventMetadata> event_metadata() noexcept { return kEvents; }",
                "",
                "Result<Client> Client::connect(ClientOptions options) {",
                "    auto core = detail::ClientCore::connect(std::move(options));",
                "    if (!core) return std::move(core).error();",
                "    return Client(std::move(core).value());",
                "}",
                "",
                "Result<EventStream> Client::open_event_stream(",
                "    std::string_view command, Json::Object parameters,",
                "    std::string terminal_event, RequestOptions options) {",
                "    auto opened = core_.open_stream(",
                "        command, std::move(parameters), std::move(terminal_event), options.timeout);",
                "    if (!opened) return std::move(opened).error();",
                "    return std::move(opened).value().map<Event>(",
                "        [](const Json& event) { return decode_value<Event>(event); });",
                "}",
                "",
            ]
        )
        for wire_name, command in self.ir.commands.items():
            assert isinstance(command, Mapping)
            lines.extend(self._command_method(wire_name, command))

        if "subscribe" in self.request_names:
            request = self.request_names["subscribe"]
            terminal = self.ir.commands["subscribe"]["stream"]["terminal_event"]
            terminal_text = "" if terminal is None else str(terminal)
            lines.extend(
                [
                    "Result<DeltaStream> Client::subscribe_deltas(",
                    f"    const {request}& request, RequestOptions options) {{",
                    "    auto encoded = encode_value(request);",
                    "    if (!encoded) return std::move(encoded).error();",
                    "    auto parameters = encoded.value().as_object();",
                    "    if (!parameters) return std::move(parameters).error();",
                    '    (*parameters.value())["tree_events"] = Json("deltas");',
                    f'    return open_event_stream("subscribe", *parameters.value(), "{terminal_text}", options);',
                    "}",
                    "",
                ]
            )
        if "attach-surface" in self.request_names:
            request = self.request_names["attach-surface"]
            terminal = self.ir.commands["attach-surface"]["stream"]["terminal_event"]
            terminal_text = "" if terminal is None else str(terminal)
            for helper, mode, stream_type in (
                ("attach_bytes", "bytes", "ByteStream"),
                ("attach_render", "render", "RenderStream"),
                ("attach_browser", "bytes", "BrowserStream"),
            ):
                mode_line = (
                    '    parameters.value()->erase("mode");'
                    if mode == "bytes"
                    else f'    (*parameters.value())["mode"] = Json("{mode}");'
                )
                lines.extend(
                    [
                        f"Result<{stream_type}> Client::{helper}(",
                        f"    const {request}& request, RequestOptions options) {{",
                        "    auto encoded = encode_value(request);",
                        "    if (!encoded) return std::move(encoded).error();",
                        "    auto parameters = encoded.value().as_object();",
                        "    if (!parameters) return std::move(parameters).error();",
                        mode_line,
                        f'    return open_event_stream("attach-surface", *parameters.value(), "{terminal_text}", options);',
                        "}",
                        "",
                    ]
                )
        lines.extend(["}  // namespace cmux::raw", ""])
        return "\n".join(lines)

    def render(self) -> dict[PurePosixPath, str]:
        return {
            PurePosixPath("include/cmux/raw/generated/models.hpp"): self.models_header(),
            PurePosixPath("include/cmux/raw/generated/events.hpp"): self.events_header(),
            PurePosixPath("include/cmux/raw/generated/commands.hpp"): self.commands_header(),
            PurePosixPath("src/raw/generated/protocol.cpp"): self.source(),
        }


def emit(ir: SdkIR) -> Mapping[str | PurePosixPath, str | bytes]:
    return CppEmitter(ir).render()


EMITTER = Emitter(
    language="cpp",
    output_root=PurePosixPath("cpp"),
    render=emit,
)
