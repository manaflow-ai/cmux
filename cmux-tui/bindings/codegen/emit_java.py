"""Deterministic Java 17 protocol model and typed command emitter."""

from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from collections.abc import Mapping
from pathlib import Path, PurePosixPath
from typing import Any

from codegen.ir import SdkIR, mutable_document
from codegen.writer import Emitter

_JAVA_RESERVED = {
    "abstract", "assert", "boolean", "break", "byte", "case", "catch",
    "char", "class", "const", "continue", "default", "do", "double",
    "else", "enum", "exports", "extends", "final", "finally", "float",
    "for", "goto", "if", "implements", "import", "instanceof", "int",
    "interface", "long", "module", "native", "new", "non-sealed", "open",
    "opens", "package", "permits", "private", "protected", "provides",
    "public", "record", "requires", "return", "sealed", "short", "static",
    "strictfp", "super", "switch", "synchronized", "this", "throw",
    "throws", "to", "transient", "transitive", "try", "uses", "var", "void",
    "volatile", "while", "with", "yield", "true", "false", "null", "_",
}

_HEADER = """// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;

"""
_JAVA_PACKAGE_MANIFEST = (
    Path(__file__).resolve().parents[1] / "java" / "pom.xml"
)
_SDK_VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def _read_sdk_version(manifest: Path) -> str:
    try:
        root = ET.parse(manifest).getroot()
    except (OSError, ET.ParseError) as error:
        raise ValueError(
            f"cannot read Java package version from {manifest}: {error}"
        ) from error
    namespace = ""
    if root.tag.startswith("{") and "}" in root.tag:
        namespace = root.tag[1:].split("}", 1)[0]
    version_tag = f"{{{namespace}}}version" if namespace else "version"
    version = root.findtext(version_tag)
    if version is None or not _SDK_VERSION_PATTERN.fullmatch(version.strip()):
        raise ValueError(
            f"Java package manifest {manifest} must define an X.Y.Z project version"
        )
    return version.strip()


def _words(value: str) -> list[str]:
    separated = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", value)
    return [part.lower() for part in re.split(r"[^A-Za-z0-9]+", separated) if part]


def _pascal(value: str) -> str:
    return "".join(word[:1].upper() + word[1:] for word in _words(value)) or "Value"


def _camel(value: str) -> str:
    words = _words(value)
    result = (words[0] + "".join(word[:1].upper() + word[1:] for word in words[1:])) if words else "value"
    return result + "_" if result in _JAVA_RESERVED else result


def _constant(value: str) -> str:
    result = "_".join(_words(value)).upper() or "VALUE"
    if result[0].isdigit():
        result = "_" + result
    return result


def _java_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def _java_literal(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return _java_string(value)
    if isinstance(value, int):
        return f"{value}L"
    if isinstance(value, float):
        return repr(value)
    raise ValueError(f"unsupported Java literal {value!r}")


def _comment(text: str | None, indent: str = "") -> list[str]:
    if not text:
        return []
    safe = " ".join(str(text).replace("*/", "* /").split())
    return [f"{indent}/** {safe} */"]


def _boxed(type_name: str) -> str:
    return {
        "boolean": "Boolean",
        "int": "Integer",
        "long": "Long",
        "double": "Double",
    }.get(type_name, type_name)


def _primitive(type_name: str) -> bool:
    return type_name in {"boolean", "int", "long", "double"}


class Registry:
    def __init__(self) -> None:
        self.names: dict[int, str] = {}
        self.declarations: dict[str, Mapping[str, Any]] = {}
        self.implements: dict[str, set[str]] = {}
        self._fingerprints: dict[str, str] = {}

    def register(
        self,
        expr: Mapping[str, Any],
        suggested: str,
        implements: tuple[str, ...] = (),
    ) -> str | None:
        kind = expr["kind"]
        if kind not in {"enum", "object", "tagged_union", "untagged_union"}:
            self._walk(expr, suggested)
            return None
        existing = self.names.get(id(expr))
        if existing is not None:
            self.implements.setdefault(existing, set()).update(implements)
            return existing
        base = _pascal(suggested)
        fingerprint = json.dumps(expr, sort_keys=True, separators=(",", ":"))
        name = base
        suffix = 2
        while name in self.declarations and self._fingerprints[name] != fingerprint:
            name = f"{base}{suffix}"
            suffix += 1
        self.names[id(expr)] = name
        self.declarations.setdefault(name, expr)
        self._fingerprints.setdefault(name, fingerprint)
        self.implements.setdefault(name, set()).update(implements)
        self._walk(expr, name)
        return name

    def _walk(self, expr: Mapping[str, Any], parent: str) -> None:
        kind = expr["kind"]
        if kind == "alias":
            self.register(expr["target"], parent + "Value")
        elif kind == "object":
            for wire_name, field in expr["fields"].items():
                self.register(field["type"], parent + _pascal(wire_name))
        elif kind == "tagged_union":
            for wire_value, variant in expr["variants"].items():
                self.register(
                    variant,
                    parent + _pascal(str(wire_value)),
                    (parent,),
                )
        elif kind == "untagged_union":
            for index, variant in enumerate(expr["variants"], 1):
                self.register(variant, f"{parent}Variant{index}")
        elif kind == "array":
            self.register(expr["items"], parent + "Item")
        elif kind == "map":
            self.register(expr["values"], parent + "Value")


class JavaEmitter:
    def __init__(self, ir: SdkIR, sdk_version: str):
        self.ir = ir
        self.sdk_version = sdk_version
        self.document = mutable_document(ir)
        self.registry = Registry()
        self.request_exprs: dict[str, Mapping[str, Any]] = {}
        self.result_names: dict[str, str | None] = {}
        self.event_exprs: dict[str, Mapping[str, Any]] = {}
        self._register_roots()

    def _register_roots(self) -> None:
        for name, expr in self.document["types"].items():
            self.registry.register(expr, name)
        for wire_name, command in self.document["commands"].items():
            stem = _pascal(wire_name)
            request = dict(command["request"])
            request["fields"] = {
                name: field
                for name, field in request["fields"].items()
                if name not in {"cmd", "id"}
            }
            self.request_exprs[wire_name] = request
            self.registry.register(request, stem + "Request")
            result = command["result"]
            self.result_names[wire_name] = self.registry.register(result, stem + "Result")
        for wire_name, event in self.document["events"].items():
            payload = dict(event["payload"])
            payload["fields"] = {
                name: field
                for name, field in payload["fields"].items()
                if name != "event"
            }
            self.event_exprs[wire_name] = payload
            interfaces = self._event_interfaces(event)
            self.registry.register(
                payload,
                _pascal(wire_name) + "Event",
                tuple(interfaces),
            )

    @staticmethod
    def _event_interfaces(event: Mapping[str, Any]) -> list[str]:
        streams = set(event["streams"])
        result = ["ProtocolEvent"]
        if any(stream.startswith("subscribe") for stream in streams):
            result.append("SubscribeEvent")
            result.append("DeltaStreamEvent")
        if "attach-byte" in streams:
            result.append("ByteAttachEvent")
        if "attach-render" in streams:
            result.append("RenderAttachEvent")
        if "attach-browser" in streams:
            result.append("BrowserAttachEvent")
        return result

    def render(self) -> dict[str, str]:
        files: dict[str, str] = {}
        for name in sorted(self.registry.declarations):
            expr = self.registry.declarations[name]
            kind = expr["kind"]
            if kind == "enum":
                source = self._render_enum(name, expr)
            elif kind == "object":
                source = self._render_object(name, expr)
            elif kind == "tagged_union":
                source = self._render_tagged_union(name, expr)
            elif kind == "untagged_union":
                source = self._render_untagged_union(name, expr)
            else:
                raise AssertionError(kind)
            files[f"{name}.java"] = source
        files.update(self._render_support())
        return files

    def _type(self, expr: Mapping[str, Any], *, boxed: bool = False) -> str:
        kind = expr["kind"]
        if kind == "scalar":
            result = {
                "string": "String",
                "boolean": "boolean",
                "int32": "int",
                "uint16": "int",
                "uint32": "long",
                "int64": "long",
                "uint64": "UInt64",
                "float32": "double",
                "float64": "double",
            }[expr["name"]]
            return _boxed(result) if boxed else result
        if kind == "literal":
            value = expr["value"]
            if isinstance(value, str):
                return "String"
            if isinstance(value, bool):
                return "Boolean" if boxed else "boolean"
            if isinstance(value, int):
                return "Long" if boxed else "long"
            if isinstance(value, float):
                return "Double" if boxed else "double"
            return "Object"
        if kind == "alias":
            return self._type(expr["target"], boxed=boxed)
        if kind == "ref":
            name = expr["name"]
            if name == "Base64":
                return "Bytes"
            if name == "JsonValue":
                return "Object"
            target = self.document["types"].get(name)
            if target and target["kind"] in {"alias", "opaque_json"}:
                return self._type(target, boxed=boxed)
            return name
        if kind == "array":
            return f"List<{self._type(expr['items'], boxed=True)}>"
        if kind == "map":
            return f"Map<String, {self._type(expr['values'], boxed=True)}>"
        if kind == "opaque_json":
            return "Object"
        name = self.registry.names.get(id(expr))
        if name is None:
            raise ValueError(f"unregistered Java type expression {expr}")
        return name

    def _decode(self, expr: Mapping[str, Any], value: str, context: str) -> str:
        kind = expr["kind"]
        ctx = _java_string(context)
        if kind == "scalar":
            return {
                "string": f"Wire.string({value}, {ctx})",
                "boolean": f"Wire.bool({value}, {ctx})",
                "int32": f"Wire.int32({value}, {ctx})",
                "uint16": f"Wire.uint16({value}, {ctx})",
                "uint32": f"Wire.uint32({value}, {ctx})",
                "int64": f"Wire.int64({value}, {ctx})",
                "uint64": f"Wire.uint64({value}, {ctx})",
                "float32": f"Wire.float64({value}, {ctx})",
                "float64": f"Wire.float64({value}, {ctx})",
            }[expr["name"]]
        if kind == "literal":
            return (
                f"ProtocolSupport.literal({value}, {_java_literal(expr['value'])}, {ctx})"
            )
        if kind == "alias":
            return self._decode(expr["target"], value, context)
        if kind == "ref":
            name = expr["name"]
            if name == "Base64":
                return f"Wire.bytes({value}, {ctx})"
            if name == "JsonValue":
                return f"Wire.immutableJson({value})"
            target = self.document["types"][name]
            if target["kind"] in {"alias", "opaque_json"}:
                return self._decode(target, value, context)
            return f"{name}.fromWire({value})"
        if kind == "array":
            inner = self._decode(expr["items"], "item", context + " item")
            return f"Wire.array({value}, {ctx}, item -> {inner})"
        if kind == "map":
            inner = self._decode(expr["values"], "item", context + " value")
            return f"Wire.map({value}, {ctx}, item -> {inner})"
        if kind == "opaque_json":
            return f"Wire.immutableJson({value})"
        return f"{self._type(expr)}.fromWire({value})"

    def _imports(self, expr: Mapping[str, Any], extra: tuple[str, ...] = ()) -> str:
        imports = {
            "java.util.ArrayList",
            "java.util.Collections",
            "java.util.LinkedHashMap",
            "java.util.List",
            "java.util.Map",
            "java.util.Objects",
        }
        imports.update(extra)
        return "".join(f"import {name};\n" for name in sorted(imports)) + "\n"

    def _render_enum(self, name: str, expr: Mapping[str, Any]) -> str:
        constants = []
        for value in expr["values"]:
            constants.append(f"    {_constant(str(value))}({_java_literal(value)})")
        body = ",\n".join(constants) + ";\n"
        return (
            _HEADER
            + "import java.util.Objects;\n\n"
            + f"public enum {name} implements WireEnum {{\n"
            + body
            + "\n    private final Object wireValue;\n\n"
            + f"    {name}(Object wireValue) {{\n"
            + "        this.wireValue = wireValue;\n"
            + "    }\n\n"
            + "    @Override\n"
            + "    public String wireValue() {\n"
            + "        return String.valueOf(wireValue);\n"
            + "    }\n\n"
            + "    public Object rawWireValue() {\n"
            + "        return wireValue;\n"
            + "    }\n\n"
            + f"    public static {name} fromWire(Object value) {{\n"
            + f"        for ({name} candidate : values()) {{\n"
            + "            if (Objects.equals(candidate.wireValue, value)\n"
            + "                    || Objects.equals(String.valueOf(candidate.wireValue), value)) {\n"
            + "                return candidate;\n"
            + "            }\n"
            + "        }\n"
            + f"        throw new CmuxDecodeException(\"unknown {name} value \" + value, null);\n"
            + "    }\n"
            + "}\n"
        )

    def _render_object(self, name: str, expr: Mapping[str, Any]) -> str:
        fields = expr["fields"]
        event_wire = self._event_wire_for_name(name)
        interfaces = sorted(self.registry.implements.get(name, set()))
        implements = ["WireValue", *[item for item in interfaces if item != "WireValue"]]
        implements_text = " implements " + ", ".join(dict.fromkeys(implements))
        lines = [_HEADER, self._imports(expr)]
        lines.extend(_comment(self._object_doc(name)))
        lines.append(f"public final class {name}{implements_text} {{")
        literal_fields: dict[str, Mapping[str, Any]] = {}
        normal_fields: dict[str, Mapping[str, Any]] = {}
        for wire_name, field in fields.items():
            if self._is_constant_literal(field):
                literal_fields[wire_name] = field
            else:
                normal_fields[wire_name] = field
        for wire_name, field in normal_fields.items():
            java_name = _camel(wire_name)
            java_type = self._field_type(field)
            lines.extend(_comment(field.get("description"), "    "))
            lines.append(f"    private final {java_type} {java_name};")
        if expr["additional_properties"]:
            lines.append("    private final Map<String, Object> additionalProperties;")
        lines.append("")
        lines.append(f"    private {name}(Builder builder) {{")
        for wire_name, field in normal_fields.items():
            java_name = _camel(wire_name)
            if field["presence"] == "required":
                lines.append(
                    f"        if (!builder.{java_name}Set) throw new IllegalArgumentException("
                    + _java_string(f"{wire_name} is required")
                    + ");"
                )
                assignment = f"builder.{java_name}"
                if not field["nullable"] and not _primitive(self._type(field["type"])):
                    assignment = f"Wire.nonNull({assignment}, {_java_string(wire_name)})"
                assignment = self._copy_expr(field["type"], assignment)
                if field["nullable"] and self._needs_copy(field["type"]):
                    assignment = (
                        f"builder.{java_name} == null ? null : "
                        f"{self._copy_expr(field['type'], f'builder.{java_name}')}"
                    )
                lines.append(f"        this.{java_name} = {assignment};")
            else:
                if self._needs_copy(field["type"]):
                    copied = self._copy_expr(field["type"], "value")
                    lines.append(
                        f"        this.{java_name} = builder.{java_name}.map(value -> {copied});"
                    )
                else:
                    lines.append(f"        this.{java_name} = builder.{java_name};")
        if expr["additional_properties"]:
            lines.append(
                "        this.additionalProperties = Collections.unmodifiableMap("
                "new LinkedHashMap<>(builder.additionalProperties));"
            )
        lines.append("    }")
        lines.append("")
        lines.append("    public static Builder builder() { return new Builder(); }")
        lines.append("")
        for wire_name, field in fields.items():
            java_name = _camel(wire_name)
            if self._is_constant_literal(field):
                return_type = self._type(field["type"], boxed=True)
                lines.append(
                    f"    public {return_type} {java_name}() {{ return "
                    f"{_java_literal(field['type']['value'])}; }}"
                )
            else:
                lines.append(
                    f"    public {self._field_type(field)} {java_name}() {{ return {java_name}; }}"
                )
        if event_wire is not None:
            lines.append(
                f"    @Override public String event() {{ return {_java_string(event_wire)}; }}"
            )
        if expr["additional_properties"]:
            lines.append(
                "    public Map<String, Object> additionalProperties() { return additionalProperties; }"
            )
        lines.append("")
        lines.append(f"    public static {name} fromWire(Object value) {{")
        lines.append(
            f"        Map<String, Object> object = Wire.object(value, {_java_string(name)});"
        )
        lines.append("        Builder builder = builder();")
        if event_wire is not None:
            lines.append(
                "        ProtocolSupport.literal(Wire.required(object, \"event\"), "
                f"{_java_string(event_wire)}, {_java_string(name + '.event')});"
            )
        known = []
        for wire_name, field in fields.items():
            known.append(wire_name)
            aliases = "".join(
                ", " + _java_string(alias) for alias in field.get("aliases", [])
            )
            raw_name = "raw" + _pascal(wire_name)
            if field["presence"] == "required":
                lines.append(
                    f"        Object {raw_name} = Wire.required(object, "
                    f"{_java_string(wire_name)}{aliases});"
                )
                if self._is_constant_literal(field):
                    lines.append(
                        "        ProtocolSupport.literal("
                        f"{raw_name}, {_java_literal(field['type']['value'])}, "
                        f"{_java_string(name + '.' + wire_name)});"
                    )
                else:
                    decoded = self._nullable_decode(
                        field,
                        raw_name,
                        name + "." + wire_name,
                    )
                    lines.append(f"        builder.{java_name_for(wire_name)}({decoded});")
            else:
                lines.append(
                    f"        Object {raw_name} = Wire.optional(object, "
                    f"{_java_string(wire_name)}{aliases});"
                )
                lines.append(f"        if (!Wire.isMissing({raw_name})) {{")
                if self._is_constant_literal(field):
                    lines.append(
                        "            ProtocolSupport.literal("
                        f"{raw_name}, {_java_literal(field['type']['value'])}, "
                        f"{_java_string(name + '.' + wire_name)});"
                    )
                else:
                    decoded = self._nullable_decode(
                        field,
                        raw_name,
                        name + "." + wire_name,
                    )
                    lines.append(
                        f"            builder.{java_name_for(wire_name)}({decoded});"
                    )
                lines.append("        }")
        if expr["additional_properties"]:
            if event_wire is not None:
                known.append("event")
            keys = ", ".join(_java_string(item) for item in known)
            lines.append(f"        List<String> known = List.of({keys});")
            lines.append(
                "        object.forEach((key, item) -> { if (!known.contains(key)) "
                "builder.putAdditional(key, Wire.immutableJson(item)); });"
            )
        lines.append("        return builder.build();")
        lines.append("    }")
        lines.append("")
        lines.append("    @Override")
        lines.append("    public Map<String, Object> toWire() {")
        lines.append("        LinkedHashMap<String, Object> object = new LinkedHashMap<>();")
        if event_wire is not None:
            lines.append(
                f"        object.put(\"event\", {_java_string(event_wire)});"
            )
        for wire_name, field in fields.items():
            if self._is_constant_literal(field):
                lines.append(
                    f"        Wire.put(object, {_java_string(wire_name)}, "
                    f"{_java_literal(field['type']['value'])});"
                )
            else:
                lines.append(
                    f"        Wire.put(object, {_java_string(wire_name)}, {_camel(wire_name)});"
                )
        if expr["additional_properties"]:
            lines.append(
                "        additionalProperties.forEach((key, value) -> "
                "object.putIfAbsent(key, Wire.encode(value)));"
            )
        lines.append("        return Collections.unmodifiableMap(object);")
        lines.append("    }")
        lines.append("")
        lines.append("    @Override")
        lines.append("    public boolean equals(Object other) {")
        lines.append(f"        if (!(other instanceof {name} that)) return false;")
        comparisons = [
            f"Objects.equals({java_name_for(wire_name)}, that.{java_name_for(wire_name)})"
            for wire_name in normal_fields
        ]
        if expr["additional_properties"]:
            comparisons.append(
                "Objects.equals(additionalProperties, that.additionalProperties)"
            )
        lines.append(
            "        return " + (" && ".join(comparisons) if comparisons else "true") + ";"
        )
        lines.append("    }")
        lines.append("")
        hash_values = [java_name_for(wire_name) for wire_name in normal_fields]
        if expr["additional_properties"]:
            hash_values.append("additionalProperties")
        lines.append("    @Override")
        lines.append(
            "    public int hashCode() { return Objects.hash("
            + ", ".join(hash_values)
            + "); }"
        )
        lines.append("")
        lines.append("    @Override")
        lines.append(
            f"    public String toString() {{ return {_java_string(name)} + toWire(); }}"
        )
        lines.append("")
        lines.append("    public static final class Builder {")
        for wire_name, field in normal_fields.items():
            java_name = _camel(wire_name)
            if field["presence"] == "required":
                builder_type = _boxed(self._type(field["type"]))
                lines.append(f"        private {builder_type} {java_name};")
                lines.append(f"        private boolean {java_name}Set;")
            else:
                builder_type = self._type(field["type"], boxed=True)
                lines.append(
                    f"        private Field<{builder_type}> {java_name} = Field.omitted();"
                )
        if expr["additional_properties"]:
            lines.append(
                "        private final LinkedHashMap<String, Object> additionalProperties = "
                "new LinkedHashMap<>();"
            )
        lines.append("")
        for wire_name, field in normal_fields.items():
            java_name = _camel(wire_name)
            parameter_type = self._type(field["type"], boxed=field["nullable"])
            if field["presence"] == "optional":
                parameter_type = self._type(field["type"], boxed=True)
            lines.append(
                f"        public Builder {java_name}({parameter_type} value) {{"
            )
            if field["type"]["kind"] == "literal":
                expected = _java_literal(field["type"]["value"])
                context = _java_string(name + "." + wire_name)
                if field["nullable"]:
                    lines.append(
                        f"            if (value != null) ProtocolSupport.literal("
                        f"value, {expected}, {context});"
                    )
                else:
                    lines.append(
                        f"            ProtocolSupport.literal(value, {expected}, {context});"
                    )
            if field["presence"] == "required":
                lines.append(f"            this.{java_name} = value;")
                lines.append(f"            this.{java_name}Set = true;")
            else:
                factory = "ofNullable" if field["nullable"] else "of"
                lines.append(f"            this.{java_name} = Field.{factory}(value);")
            lines.append("            return this;")
            lines.append("        }")
        if expr["additional_properties"]:
            lines.extend(
                [
                    "        public Builder putAdditional(String key, Object value) {",
                    "            additionalProperties.put(Wire.nonNull(key, \"key\"), Wire.immutableJson(value));",
                    "            return this;",
                    "        }",
                ]
            )
        lines.append(f"        public {name} build() {{ return new {name}(this); }}")
        lines.append("    }")
        lines.append("}")
        return "\n".join(lines) + "\n"

    @staticmethod
    def _is_constant_literal(field: Mapping[str, Any]) -> bool:
        return (
            field["type"]["kind"] == "literal"
            and field["presence"] == "required"
            and not field["nullable"]
        )

    def _field_type(self, field: Mapping[str, Any]) -> str:
        value_type = self._type(
            field["type"],
            boxed=field["nullable"] or field["presence"] == "optional",
        )
        if field["presence"] == "optional":
            return f"Field<{value_type}>"
        return value_type

    def _nullable_decode(
        self,
        field: Mapping[str, Any],
        value: str,
        context: str,
    ) -> str:
        decoded = self._decode(field["type"], value, context)
        return f"{value} == null ? null : {decoded}" if field["nullable"] else decoded

    def _copy_expr(self, expr: Mapping[str, Any], value: str) -> str:
        kind = expr["kind"]
        if kind == "array":
            return f"List.copyOf({value})"
        if kind == "map":
            return f"Collections.unmodifiableMap(new LinkedHashMap<>({value}))"
        if kind == "opaque_json":
            return f"Wire.immutableJson({value})"
        if kind == "ref" and expr["name"] == "JsonValue":
            return f"Wire.immutableJson({value})"
        return value

    def _needs_copy(self, expr: Mapping[str, Any]) -> bool:
        kind = expr["kind"]
        if kind in {"array", "map", "opaque_json"}:
            return True
        if kind == "alias":
            return self._needs_copy(expr["target"])
        if kind == "ref":
            return expr["name"] == "JsonValue"
        return False

    def _event_wire_for_name(self, name: str) -> str | None:
        for wire_name, expr in self.event_exprs.items():
            if self.registry.names.get(id(expr)) == name:
                return wire_name
        return None

    def _object_doc(self, name: str) -> str | None:
        for wire_name, expr in self.request_exprs.items():
            if self.registry.names.get(id(expr)) == name:
                command = self.document["commands"][wire_name]
                return (
                    f"Immutable {wire_name} request. Protocol v{command['since']}; "
                    f"authority: {command['authority']}."
                )
        for wire_name, expr in self.event_exprs.items():
            if self.registry.names.get(id(expr)) == name:
                event = self.document["events"][wire_name]
                return (
                    f"Immutable {wire_name} event. Protocol v{event['since']}; "
                    f"streams: {', '.join(event['streams']) or 'none'}."
                )
        return None

    def _render_tagged_union(self, name: str, expr: Mapping[str, Any]) -> str:
        lines = [
            _HEADER,
            "import java.util.Map;\n\n",
            f"public interface {name} extends WireValue {{",
            f"    static {name} fromWire(Object value) {{",
            f"        Map<String, Object> object = Wire.object(value, {_java_string(name)});",
            f"        String tag = Wire.string(Wire.required(object, {_java_string(expr['tag'])}), "
            f"{_java_string(name + '.' + expr['tag'])});",
            "        return switch (tag) {",
        ]
        for wire_value, variant in expr["variants"].items():
            variant_name = self.registry.names[id(variant)]
            lines.append(
                f"            case {_java_string(str(wire_value))} -> {variant_name}.fromWire(value);"
            )
        lines.extend(
            [
                f"            default -> throw new CmuxDecodeException("
                f"\"unknown {name} tag \" + tag, null);",
                "        };",
                "    }",
                "}",
            ]
        )
        return "\n".join(lines) + "\n"

    def _render_untagged_union(self, name: str, expr: Mapping[str, Any]) -> str:
        variants: list[tuple[str, str, Mapping[str, Any]]] = []
        used_labels: set[str] = set()
        for index, variant in enumerate(expr["variants"], 1):
            if variant["kind"] == "ref":
                label = _pascal(variant["name"])
            elif variant["kind"] == "scalar":
                label = _pascal(variant["name"])
            else:
                label = self.registry.names.get(id(variant), f"Variant{index}")
            base = label
            suffix = 2
            while label in used_labels:
                label = f"{base}{suffix}"
                suffix += 1
            used_labels.add(label)
            variants.append((label, self._type(variant, boxed=True), variant))
        lines = [
            _HEADER,
            "import java.util.Objects;\n\n",
            f"public final class {name} implements WireValue {{",
            "    public enum Kind { "
            + ", ".join(_constant(label) for label, _, _ in variants)
            + " }",
            "    private final Kind kind;",
            "    private final Object value;",
            f"    private {name}(Kind kind, Object value) {{",
            "        this.kind = kind;",
            "        this.value = Objects.requireNonNull(value, \"value\");",
            "    }",
            "    public Kind kind() { return kind; }",
            "    public Object value() { return value; }",
            "",
        ]
        for label, java_type, _ in variants:
            method = _camel(label)
            constant = _constant(label)
            lines.extend(
                [
                    f"    public static {name} of{label}({java_type} value) {{",
                    f"        return new {name}(Kind.{constant}, value);",
                    "    }",
                    f"    public boolean is{label}() {{ return kind == Kind.{constant}; }}",
                    f"    public {java_type} {method}() {{",
                    f"        if (!is{label}()) throw new IllegalStateException("
                    f"\"{name} contains \" + kind);",
                    f"        return ({java_type}) value;",
                    "    }",
                    "",
                ]
            )
        lines.extend(
            [
                f"    public static {name} fromWire(Object raw) {{",
            "        CmuxDecodeException last = null;",
            ]
        )
        for index, (label, _, variant) in enumerate(variants, 1):
            decoded = self._decode(variant, "raw", name + f" variant {index}")
            lines.extend(
                [
                    "        try {",
                    f"            return of{label}({decoded});",
                    "        } catch (CmuxDecodeException error) {",
                    "            last = error;",
                    "        }",
                ]
            )
        lines.extend(
            [
                f"        throw new CmuxDecodeException(\"no {name} variant matched\", last);",
                "    }",
                "",
            "    @Override",
            "    public Object toWire() { return Wire.encode(value); }",
            "",
            "    @Override",
            f"    public boolean equals(Object other) {{ return other instanceof {name} that "
            "&& kind == that.kind && Objects.equals(value, that.value); }",
            "    @Override public int hashCode() { return Objects.hash(kind, value); }",
            f"    @Override public String toString() {{ return \"{name}[\" + value + \"]\"; }}",
            "}",
        ]
        )
        return "\n".join(lines) + "\n"

    def _render_support(self) -> dict[str, str]:
        return {
            "Authority.java": self._authority_source(),
            "StreamKind.java": self._stream_kind_source(),
            "CommandMetadata.java": self._command_metadata_source(),
            "EventMetadata.java": self._event_metadata_source(),
            "Commands.java": self._commands_source(),
            "Events.java": self._events_source(),
            "Protocol.java": self._protocol_source(),
            "ProtocolSupport.java": self._protocol_support_source(),
            "ProtocolEvent.java": self._marker_source("ProtocolEvent", None),
            "SubscribeEvent.java": self._marker_source("SubscribeEvent", "ProtocolEvent"),
            "DeltaStreamEvent.java": self._marker_source("DeltaStreamEvent", "SubscribeEvent"),
            "ByteAttachEvent.java": self._marker_source("ByteAttachEvent", "ProtocolEvent"),
            "RenderAttachEvent.java": self._marker_source("RenderAttachEvent", "ProtocolEvent"),
            "BrowserAttachEvent.java": self._marker_source("BrowserAttachEvent", "ProtocolEvent"),
            "UnknownEvent.java": self._unknown_event_source(),
            "GeneratedCmuxClient.java": self._client_source(),
        }

    @staticmethod
    def _marker_source(name: str, parent: str | None) -> str:
        extends = f" extends {parent}" if parent else ""
        methods = (
            "\n    String event();\n    java.util.Map<String, Object> toWire();\n"
            if name == "ProtocolEvent"
            else ""
        )
        return _HEADER + f"public interface {name}{extends} {{{methods}}}\n"

    def _authority_source(self) -> str:
        constants = []
        for authority in sorted(
            {command["authority"] for command in self.document["commands"].values()}
        ):
            constants.append(
                f"    {_constant(authority)}({_java_string(authority)})"
            )
        return (
            _HEADER
            + "public enum Authority implements WireEnum {\n"
            + ",\n".join(constants)
            + ";\n\n"
            + "    private final String wireValue;\n"
            + "    Authority(String wireValue) { this.wireValue = wireValue; }\n"
            + "    @Override public String wireValue() { return wireValue; }\n"
            + "}\n"
        )

    @staticmethod
    def _stream_kind_source() -> str:
        return (
            _HEADER
            + "public enum StreamKind {\n"
            + "    NONE, SUBSCRIBE, ATTACH\n"
            + "}\n"
        )

    @staticmethod
    def _command_metadata_source() -> str:
        return (
            _HEADER
            + "import java.util.Map;\n\n"
            + "public record CommandMetadata(\n"
            + "    String wireName,\n"
            + "    Authority authority,\n"
            + "    int since,\n"
            + "    String capability,\n"
            + "    StreamKind streamKind,\n"
            + "    Map<String, Long> fieldSince,\n"
            + "    Map<String, String> fieldCapabilities\n"
            + ") {\n"
            + "    public CommandMetadata {\n"
            + "        fieldSince = Map.copyOf(fieldSince);\n"
            + "        fieldCapabilities = Map.copyOf(fieldCapabilities);\n"
            + "    }\n"
            + "}\n"
        )

    @staticmethod
    def _event_metadata_source() -> str:
        return (
            _HEADER
            + "import java.util.List;\n\n"
            + "public record EventMetadata(\n"
            + "    String wireName,\n"
            + "    int since,\n"
            + "    String capability,\n"
            + "    List<String> streams,\n"
            + "    boolean emitted\n"
            + ") {\n"
            + "    public EventMetadata { streams = List.copyOf(streams); }\n"
            + "}\n"
        )

    def _commands_source(self) -> str:
        lines = [
            _HEADER,
            "import java.util.Collections;\n"
            "import java.util.LinkedHashMap;\n"
            "import java.util.Map;\n\n",
            "public final class Commands {",
            "    private Commands() {}",
            "",
        ]
        for wire_name, command in self.document["commands"].items():
            stream = command["stream"]
            stream_kind = (
                "NONE" if stream is None else _constant(stream["kind"])
            )
            capability = _java_literal(command["capability"])
            field_since = {
                name: field["since"]
                for name, field in command["request"]["fields"].items()
                if "since" in field
            }
            field_capabilities = {
                name: field["capability"]
                for name, field in command["request"]["fields"].items()
                if "capability" in field
            }
            lines.append(
                f"    public static final CommandMetadata {_constant(wire_name)} = "
                f"new CommandMetadata({_java_string(wire_name)}, "
                f"Authority.{_constant(command['authority'])}, {command['since']}, "
                f"{capability}, StreamKind.{stream_kind}, "
                f"{self._java_map(field_since)}, "
                f"{self._java_map(field_capabilities)});"
            )
        lines.extend(
            [
                "",
                "    public static final Map<String, CommandMetadata> ALL;",
                "    static {",
                "        LinkedHashMap<String, CommandMetadata> values = new LinkedHashMap<>();",
            ]
        )
        for wire_name in self.document["commands"]:
            lines.append(
                f"        values.put({_java_string(wire_name)}, {_constant(wire_name)});"
            )
        lines.extend(
            [
                "        ALL = Collections.unmodifiableMap(values);",
                "    }",
                "}",
            ]
        )
        return "\n".join(lines) + "\n"

    @staticmethod
    def _java_map(values: Mapping[str, Any]) -> str:
        if not values:
            return "Map.of()"
        entries = ", ".join(
            f"Map.entry({_java_string(name)}, {_java_literal(value)})"
            for name, value in sorted(values.items())
        )
        return f"Map.ofEntries({entries})"

    def _events_source(self) -> str:
        lines = [
            _HEADER,
            "import java.util.Collections;\n"
            "import java.util.LinkedHashMap;\n"
            "import java.util.List;\n"
            "import java.util.Map;\n\n",
            "public final class Events {",
            "    private Events() {}",
            "",
        ]
        for wire_name, event in self.document["events"].items():
            streams = ", ".join(_java_string(item) for item in event["streams"])
            lines.append(
                f"    public static final EventMetadata {_constant(wire_name)} = "
                f"new EventMetadata({_java_string(wire_name)}, {event['since']}, "
                f"{_java_literal(event['capability'])}, List.of({streams}), "
                f"{str(event['emission'] == 'emitted').lower()});"
            )
        lines.extend(
            [
                "",
                "    public static final Map<String, EventMetadata> ALL;",
                "    static {",
                "        LinkedHashMap<String, EventMetadata> values = new LinkedHashMap<>();",
            ]
        )
        for wire_name in self.document["events"]:
            lines.append(
                f"        values.put({_java_string(wire_name)}, {_constant(wire_name)});"
            )
        lines.extend(
            [
                "        ALL = Collections.unmodifiableMap(values);",
                "    }",
                "}",
            ]
        )
        return "\n".join(lines) + "\n"

    def _protocol_source(self) -> str:
        lines = [
            _HEADER,
            "import java.util.Map;\n\n",
            "public final class Protocol {",
            f"    public static final String SDK_VERSION = {_java_string(self.sdk_version)};",
            f"    public static final int VERSION = {self.ir.mux_protocol};",
            f"    public static final int SCHEMA_VERSION = {self.ir.schema_version};",
            f"    public static final String IR_SHA256 = {_java_string(self.ir.ir_sha256)};",
            "    private Protocol() {}",
            "",
            "    public static ProtocolEvent decodeEvent(Object value) {",
            "        Map<String, Object> object = Wire.object(value, \"event\");",
            "        String event = Wire.string(Wire.required(object, \"event\"), \"event.event\");",
            "        return switch (event) {",
        ]
        for wire_name, expr in self.event_exprs.items():
            event_name = self.registry.names[id(expr)]
            lines.append(
                f"            case {_java_string(wire_name)} -> {event_name}.fromWire(value);"
            )
        lines.extend(
            [
                "            default -> UnknownEvent.fromWire(value);",
                "        };",
                "    }",
                "}",
            ]
        )
        return "\n".join(lines) + "\n"

    @staticmethod
    def _protocol_support_source() -> str:
        return (
            _HEADER
            + "import java.math.BigDecimal;\n"
            + "import java.math.BigInteger;\n"
            + "import java.util.Objects;\n\n"
            + "final class ProtocolSupport {\n"
            + "    private ProtocolSupport() {}\n"
            + "    static <T> T literal(Object actual, T expected, String context) {\n"
            + "        boolean equal = Objects.equals(actual, expected);\n"
            + "        if (!equal && actual instanceof Number a && expected instanceof Number e) {\n"
            + "            equal = new BigDecimal(a.toString()).compareTo(new BigDecimal(e.toString())) == 0;\n"
            + "        }\n"
            + "        if (!equal) throw new CmuxDecodeException(context + \" must equal \" + expected, null);\n"
            + "        return expected;\n"
            + "    }\n"
            + "}\n"
        )

    @staticmethod
    def _unknown_event_source() -> str:
        return (
            _HEADER
            + "import java.util.Collections;\n"
            + "import java.util.LinkedHashMap;\n"
            + "import java.util.Map;\n\n"
            + "public final class UnknownEvent implements SubscribeEvent, DeltaStreamEvent, "
            + "ByteAttachEvent, RenderAttachEvent, BrowserAttachEvent {\n"
            + "    private final String event;\n"
            + "    private final Map<String, Object> raw;\n"
            + "    @SuppressWarnings(\"unchecked\")\n"
            + "    private UnknownEvent(String event, Map<String, Object> raw) {\n"
            + "        this.event = event;\n"
            + "        this.raw = (Map<String, Object>) Wire.immutableJson(raw);\n"
            + "    }\n"
            + "    public static UnknownEvent fromWire(Object value) {\n"
            + "        Map<String, Object> raw = Wire.object(value, \"unknown event\");\n"
            + "        return new UnknownEvent(Wire.string(Wire.required(raw, \"event\"), "
            + "\"unknown event.event\"), raw);\n"
            + "    }\n"
            + "    @Override public String event() { return event; }\n"
            + "    public Map<String, Object> raw() { return raw; }\n"
            + "    @Override public Map<String, Object> toWire() { return raw; }\n"
            + "}\n"
        )

    def _client_source(self) -> str:
        lines = [
            _HEADER,
            "import java.util.List;\n"
            "import java.util.Map;\n\n",
            "/** Canonical typed method surface for every implemented protocol command. */",
            "public abstract class GeneratedCmuxClient {",
            "    protected abstract Object execute(CommandMetadata metadata, Map<String, Object> params)",
            "        throws CmuxException;",
            "    protected abstract CmuxStream<ProtocolEvent> openStream(",
            "        CommandMetadata metadata, Map<String, Object> params",
            "    ) throws CmuxException;",
            "",
        ]
        for wire_name, command in self.document["commands"].items():
            request = self.request_exprs[wire_name]
            request_name = self.registry.names[id(request)]
            method = _camel(wire_name)
            metadata = f"Commands.{_constant(wire_name)}"
            has_fields = bool(request["fields"])
            parameter = f"{request_name} request" if has_fields else ""
            params = "request.toWire()" if has_fields else "Map.of()"
            result_type = self._type(command["result"])
            if command["stream"] is not None:
                lines.append(
                    f"    public final CmuxStream<ProtocolEvent> {method}({parameter}) "
                    "throws CmuxException {"
                )
                lines.append(f"        return openStream({metadata}, {params});")
            else:
                lines.append(
                    f"    public final {result_type} {method}({parameter}) throws CmuxException {{"
                )
                lines.append(f"        Object result = execute({metadata}, {params});")
                lines.append(
                    f"        return {self._decode(command['result'], 'result', wire_name + ' result')};"
                )
            lines.append("    }")
            lines.append("")
        lines.append("}")
        return "\n".join(lines) + "\n"


def java_name_for(wire_name: str) -> str:
    return _camel(wire_name)


def emit(
    ir: SdkIR,
    *,
    version_manifest: Path = _JAVA_PACKAGE_MANIFEST,
) -> Mapping[str | PurePosixPath, str | bytes]:
    return JavaEmitter(ir, _read_sdk_version(version_manifest)).render()


EMITTER = Emitter(
    language="java",
    output_root=PurePosixPath("java/src/com/cmux/raw"),
    render=emit,
)
