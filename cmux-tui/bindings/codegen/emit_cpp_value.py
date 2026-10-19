"""Deterministic base::Value codec emitter for Chromium (cmux-browser).

This backend reads the same SDK IR as ``emit_cpp.py`` (``spec/sdk-schema.json``)
but writes Chromium C++: plain structs, ``base::Value`` encoders and
``base::expected`` decoders in namespace ``cmux::daemon``. It emits only the
type closure of an allowlist of commands and events, because the browser uses
a small part of the protocol.

Contract: ``plans/cmux-next/cmux-browser-rewrite-a.md`` (0e1) and section 6 of
``docs/rewrite/contracts-a.md`` in manaflow-ai/cmux-browser.

Entry point: ``generate.py --cpp-value --allowlist FILE --out DIR``. It is not
an SDK language: ``generate.py --write`` does not discover it (see
``generate.NON_SDK_EMITTERS``).

Rules that the emitted code follows:

- Integers decode from a ``base::Value`` int, or from a double that is an exact
  integer with a magnitude below 2^53. Anything else is a
  ``DecodeError``; there is no silent precision loss.
- Every enum gets ``kUnknown`` as its first enumerator. An unknown string
  decodes to the spec ``fallback`` value when the enum has one (the rule of
  ``tests/test_enum_fallback.py``), else to ``kUnknown``.
- Optional or nullable fields are ``std::optional``. Absent and null both
  decode to ``std::nullopt``; ``std::nullopt`` encodes as an absent key for an
  optional field and as ``null`` for a required nullable field.
- A field that is optional and nullable in a type the browser sends (a
  request or a type reached from one) is ``OptionalNullable<T>``: absent,
  explicit ``null`` and a value are three states, because the daemon reads
  them as three (``Option<Option<T>>``; for example ``null`` clears a tab's
  profile and an absent key keeps it).
- ``float32`` and ``float64`` are ``double`` (the contract maps every decimal
  to ``double``).
- Decoders ignore unknown fields. A missing required field is a
  ``DecodeError`` whose path names the field, for example
  ``result.panes[2].id``.
- A reference that closes a cycle (a type that contains itself, for example
  ``Layout``) is held in ``std::unique_ptr`` unless it is an array item.
- The request envelope (``id``, ``method``) and v2 resource operations are not
  part of this codec.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from codegen.ir import SdkIR
from codegen.naming import pascal_case, snake_case
from codegen.writer import GenerationError, NondeterministicGenerationError

ALLOWLIST_SCHEMA = "cmux-tui-spec-allowlist-v1"
DEFAULT_INCLUDE_PATH = "third_party/cmux_tui_spec/cmux_daemon_types.h"
HEADER_NAME = "cmux_daemon_types.h"
SOURCE_NAME = "cmux_daemon_types.cc"
OUTPUT_NAMES = (HEADER_NAME, SOURCE_NAME)

# C++ keywords plus names that common platform headers define as macros
# (glibc <sys/sysmacros.h>, <windows.h>, <rpcndr.h>, <stdio.h>, <errno.h>).
_CPP_RESERVED = frozenset(
    """
    alignas alignof and and_eq asm atomic_cancel atomic_commit atomic_noexcept
    auto bitand bitor bool break case catch char char8_t char16_t char32_t class
    compl concept const consteval constexpr constinit const_cast continue
    co_await co_return co_yield decltype default delete do double dynamic_cast
    else enum explicit export extern false float for friend goto if import
    inline int long module mutable namespace new noexcept not not_eq nullptr
    operator or or_eq private protected public reflexpr register
    reinterpret_cast requires return short signed sizeof static static_assert
    static_cast struct switch synchronized template this thread_local throw
    true try typedef typeid typename union unsigned using virtual void volatile
    wchar_t while xor xor_eq
    linux unix major minor makedev errno assert stdin stdout stderr
    interface small near far min max hyper pascal cdecl
    """.split()
)

# Names the generated header defines itself.
_RESERVED_TYPE_NAMES = frozenset(
    {"DecodeError", "UnknownEvent", "Event", "OptionalNullable"}
)

_SCALAR_TYPES = {
    "string": "std::string",
    "boolean": "bool",
    "int32": "int32_t",
    "uint16": "uint16_t",
    "uint32": "uint32_t",
    "int64": "int64_t",
    "uint64": "uint64_t",
    "float32": "double",
    "float64": "double",
}

_SCALAR_DEFAULTS = {
    "string": None,
    "boolean": "false",
    "int32": "0",
    "uint16": "0",
    "uint32": "0",
    "int64": "0",
    "uint64": "0",
    "float32": "0.0",
    "float64": "0.0",
}

_STRUCT_KINDS = frozenset({"object", "tagged_union", "untagged_union"})
_MODEL_KINDS = _STRUCT_KINDS | {"enum"}


# ---------------------------------------------------------------------------
# Allowlist


@dataclass(frozen=True, slots=True)
class Allowlist:
    """The commands and events whose type closure is emitted."""

    commands: tuple[str, ...]
    events: tuple[str, ...]

    def digest(self) -> str:
        canonical = json.dumps(
            {
                "schema": ALLOWLIST_SCHEMA,
                "commands": list(self.commands),
                "events": list(self.events),
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()


def parse_allowlist(document: Any, *, source: str = "allowlist") -> Allowlist:
    """Validate an allowlist document (sorted, unique lists of names)."""

    if not isinstance(document, Mapping):
        raise GenerationError(f"{source}: must be a JSON object")
    unknown_keys = sorted(set(document) - {"schema", "commands", "events", "$comment"})
    if unknown_keys:
        raise GenerationError(
            f"{source}: unknown key(s) {', '.join(unknown_keys)}"
        )
    if document.get("schema") != ALLOWLIST_SCHEMA:
        raise GenerationError(
            f"{source}: schema must be {ALLOWLIST_SCHEMA!r}, "
            f"got {document.get('schema')!r}"
        )
    lists: dict[str, tuple[str, ...]] = {}
    for key in ("commands", "events"):
        values = document.get(key)
        if not isinstance(values, list) or not all(
            isinstance(value, str) and value for value in values
        ):
            raise GenerationError(f"{source}: {key} must be a list of names")
        if len(set(values)) != len(values):
            duplicates = sorted({value for value in values if values.count(value) > 1})
            raise GenerationError(
                f"{source}: {key} has duplicate name(s) {', '.join(duplicates)}"
            )
        if values != sorted(values):
            raise GenerationError(f"{source}: {key} must be sorted")
        lists[key] = tuple(values)
    return Allowlist(commands=lists["commands"], events=lists["events"])


def load_allowlist(path: str | Path) -> Allowlist:
    allowlist_path = Path(path)
    try:
        document = json.loads(allowlist_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GenerationError(
            f"cannot load allowlist {allowlist_path}: {error}"
        ) from error
    return parse_allowlist(document, source=str(allowlist_path))


# ---------------------------------------------------------------------------
# Naming helpers


def cpp_field_name(wire_name: str) -> str:
    result = snake_case(wire_name) or "field"
    if result[0].isdigit():
        result = f"f_{result}"
    if result in _CPP_RESERVED:
        result += "_"
    return result


def cpp_type_name(wire_name: str) -> str:
    result = pascal_case(wire_name) or "Value"
    if result[0].isdigit():
        result = f"T{result}"
    return result


def cpp_enumerator(value: str) -> str:
    base = pascal_case(value)
    if not base:
        base = "Empty"
    return f"k{base}"


def cpp_string(value: str) -> str:
    """Return a C++ narrow string literal for ``value``."""

    return json.dumps(value, ensure_ascii=True)


def include_guard(include_path: str) -> str:
    guard = "".join(
        character.upper() if character.isalnum() else "_"
        for character in include_path
    )
    return f"{guard}_"


# ---------------------------------------------------------------------------
# Emitter


@dataclass(slots=True)
class _Model:
    name: str
    expression: Mapping[str, Any]
    # "named" (a spec type), "params", "result", "event" or "nested".
    origin: str
    wire_name: str | None = None


class CppValueEmitter:
    """Renders ``cmux_daemon_types.{h,cc}`` for one allowlist."""

    def __init__(
        self,
        ir: SdkIR,
        allowlist: Allowlist,
        *,
        include_path: str = DEFAULT_INCLUDE_PATH,
    ) -> None:
        self.ir = ir
        self.allowlist = allowlist
        self.include_path = include_path
        self._check_allowlist()

        # Struct, union and enum models, by C++ name, in registration order.
        self.models: dict[str, _Model] = {}
        # id(expression) -> model name for registered expressions.
        self.expr_names: dict[int, str] = {}
        # Named alias and opaque_json types: C++ name -> C++ target type.
        self.aliases: dict[str, str] = {}
        self.params_names: dict[str, str] = {}
        self.result_types: dict[str, str] = {}
        self.result_aliases: dict[str, str] = {}
        self.event_names: dict[str, str] = {}

        self._register_named_types(self._named_type_closure())
        self._register_roots()
        self._discover_nested_models()
        self.components, self.component_for = self._ordered_components()
        self.read_models, self.write_models = self._codec_closures()

    # -- allowlist and closure ------------------------------------------------

    def _check_allowlist(self) -> None:
        unknown_commands = [
            name for name in self.allowlist.commands if name not in self.ir.commands
        ]
        if unknown_commands:
            raise GenerationError(
                "allowlist names unknown raw command(s): "
                + ", ".join(unknown_commands)
                + " (v2 resource operations are not supported by --cpp-value)"
            )
        unknown_events = [
            name for name in self.allowlist.events if name not in self.ir.events
        ]
        if unknown_events:
            raise GenerationError(
                "allowlist names unknown event(s): " + ", ".join(unknown_events)
            )

    def _root_expressions(self) -> list[Mapping[str, Any]]:
        roots: list[Mapping[str, Any]] = []
        for wire_name in self.allowlist.commands:
            command = self.ir.command(wire_name)
            roots.append(command["request"])
            roots.append(command["result"])
        for wire_name in self.allowlist.events:
            roots.append(self.ir.event(wire_name)["payload"])
        return roots

    def _named_type_closure(self) -> list[str]:
        seen: set[str] = set()
        pending = list(self._root_expressions())
        while pending:
            expression = pending.pop()
            for child in _child_expressions(expression):
                pending.append(child)
            if expression["kind"] == "ref":
                name = str(expression["name"])
                if name not in seen:
                    seen.add(name)
                    pending.append(self.ir.type(name))
        return sorted(seen)

    # -- registration ---------------------------------------------------------

    def _unique_name(self, proposed: str) -> str:
        taken = set(self.models) | set(self.aliases) | _RESERVED_TYPE_NAMES
        if proposed not in taken:
            return proposed
        index = 2
        while f"{proposed}{index}" in taken:
            index += 1
        return f"{proposed}{index}"

    def _register(
        self,
        proposed: str,
        expression: Mapping[str, Any],
        *,
        origin: str,
        exact: bool,
        wire_name: str | None = None,
    ) -> str:
        existing = self.expr_names.get(id(expression))
        if existing is not None:
            return existing
        if exact:
            if (
                proposed in self.models
                or proposed in self.aliases
                or proposed in _RESERVED_TYPE_NAMES
            ):
                raise GenerationError(
                    f"C++ type name {proposed} is used twice "
                    f"({origin} {wire_name or proposed})"
                )
            name = proposed
        else:
            name = self._unique_name(proposed)
        self.models[name] = _Model(name, expression, origin, wire_name)
        self.expr_names[id(expression)] = name
        return name

    def _register_named_types(self, names: Iterable[str]) -> None:
        for wire_name in names:
            expression = self.ir.type(wire_name)
            cpp_name = cpp_type_name(wire_name)
            kind = expression["kind"]
            if kind in _MODEL_KINDS:
                if kind == "enum":
                    self._check_enum(cpp_name, expression)
                self._register(
                    cpp_name, expression, origin="named", exact=True, wire_name=wire_name
                )
            elif kind == "alias":
                target = expression["target"]
                if target["kind"] == "scalar":
                    self._add_alias(cpp_name, _SCALAR_TYPES[str(target["name"])])
                elif target["kind"] == "opaque_json":
                    self._add_alias(cpp_name, "base::Value")
                else:
                    raise GenerationError(
                        f"type {wire_name}: --cpp-value supports aliases of "
                        f"scalars only, got {target['kind']}"
                    )
            elif kind == "opaque_json":
                self._add_alias(cpp_name, "base::Value")
            else:
                raise GenerationError(
                    f"type {wire_name}: --cpp-value does not support a named "
                    f"{kind} type"
                )

    def _add_alias(self, name: str, target: str) -> None:
        if name in self.models or name in self.aliases or name in _RESERVED_TYPE_NAMES:
            raise GenerationError(f"C++ type name {name} is used twice")
        self.aliases[name] = target

    def _register_roots(self) -> None:
        for wire_name in self.allowlist.commands:
            command = self.ir.command(wire_name)
            base = cpp_type_name(wire_name)
            request = command["request"]
            self.params_names[wire_name] = self._register(
                f"{base}Params",
                request,
                origin="params",
                exact=True,
                wire_name=wire_name,
            )
            result = command["result"]
            result_name = f"{base}Result"
            if result["kind"] in _MODEL_KINDS:
                if result["kind"] == "enum":
                    self._check_enum(result_name, result)
                self.result_types[wire_name] = self._register(
                    result_name,
                    result,
                    origin="result",
                    exact=True,
                    wire_name=wire_name,
                )
            else:
                # A reference or a container: the name is a type alias.
                self.result_types[wire_name] = result_name
                self.result_aliases[wire_name] = result_name
        for wire_name in self.allowlist.events:
            payload = self.ir.event(wire_name)["payload"]
            self.event_names[wire_name] = self._register(
                f"{cpp_type_name(wire_name)}Event",
                payload,
                origin="event",
                exact=True,
                wire_name=wire_name,
            )
        # Result aliases are declared with `using`; they must not collide with
        # a model or another alias.
        for wire_name, alias in self.result_aliases.items():
            if alias in self.models or alias in self.aliases:
                target = self.ir.command(wire_name)["result"]
                if not (
                    target["kind"] == "ref"
                    and cpp_type_name(str(target["name"])) == alias
                ):
                    raise GenerationError(
                        f"C++ type name {alias} is used twice (result of {wire_name})"
                    )

    def _discover_nested_models(self) -> None:
        position = 0
        while position < len(self.models):
            model = tuple(self.models.values())[position]
            self._discover_expression(model.name, model.expression)
            position += 1
        for wire_name in self.allowlist.commands:
            if wire_name in self.result_aliases:
                result = self.ir.command(wire_name)["result"]
                self._discover_child(self.result_aliases[wire_name], result)
                # Children found here can have children of their own.
                while position < len(self.models):
                    model = tuple(self.models.values())[position]
                    self._discover_expression(model.name, model.expression)
                    position += 1

    def _discover_expression(self, owner: str, expression: Mapping[str, Any]) -> None:
        kind = expression["kind"]
        if kind == "object":
            for wire_name, field in expression["fields"].items():
                self._discover_child(f"{owner}{cpp_type_name(wire_name)}", field["type"])
        elif kind == "tagged_union":
            for variant, variant_type in expression["variants"].items():
                if variant_type["kind"] == "object":
                    self._register(
                        f"{owner}{cpp_type_name(str(variant))}",
                        variant_type,
                        origin="nested",
                        exact=False,
                    )
                else:
                    self._discover_child(
                        f"{owner}{cpp_type_name(str(variant))}", variant_type
                    )
        elif kind == "untagged_union":
            for index, variant in enumerate(expression["variants"], start=1):
                self._discover_child(f"{owner}Variant{index}", variant)

    def _discover_child(self, proposed: str, expression: Mapping[str, Any]) -> None:
        kind = expression["kind"]
        if kind in _MODEL_KINDS:
            if kind == "enum":
                self._check_enum(proposed, expression)
            self._register(proposed, expression, origin="nested", exact=False)
        elif kind == "array":
            self._discover_child(f"{proposed}Item", expression["items"])
        elif kind == "map":
            self._discover_child(f"{proposed}Value", expression["values"])
        elif kind == "alias":
            self._discover_child(proposed, expression["target"])
        elif kind == "literal":
            _check_literal(expression["value"], where=proposed)

    @staticmethod
    def _check_enum(name: str, expression: Mapping[str, Any]) -> None:
        for value in expression["values"]:
            if not isinstance(value, str):
                raise GenerationError(
                    f"enum {name}: --cpp-value supports string enums only, "
                    f"got {value!r}"
                )

    # -- graph ----------------------------------------------------------------

    def _model_for(self, expression: Mapping[str, Any]) -> str | None:
        """Return the model that ``expression`` names, if any."""

        registered = self.expr_names.get(id(expression))
        if registered is not None:
            return registered
        if expression["kind"] == "ref":
            name = cpp_type_name(str(expression["name"]))
            if name in self.models:
                return name
        return None

    def _model_dependencies(self, model: _Model) -> set[str]:
        result: set[str] = set()

        def visit(expression: Mapping[str, Any], *, root: bool = False) -> None:
            named = None if root else self._model_for(expression)
            if named is not None:
                result.add(named)
                return
            for child in _child_expressions(expression):
                visit(child)

        visit(model.expression, root=True)
        result.discard(model.name)
        return result

    def _ordered_components(self) -> tuple[list[list[str]], dict[str, int]]:
        graph = {
            name: self._model_dependencies(model)
            for name, model in self.models.items()
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
            for dependency in sorted(
                component_dependencies[component],
                key=lambda value: sorted(raw_components[value])[0],
            ):
                order(dependency)
            ordered_ids.append(component)

        for component in sorted(
            range(len(raw_components)),
            key=lambda value: sorted(raw_components[value])[0],
        ):
            order(component)

        components: list[list[str]] = []
        component_for: dict[str, int] = {}
        for new_id, raw_id in enumerate(ordered_ids):
            # Inside a cycle, objects come first: a union's std::variant needs
            # complete alternatives, and objects reach the cycle only through
            # std::unique_ptr or std::vector.
            members = sorted(
                raw_components[raw_id],
                key=lambda name: (
                    self.models[name].expression["kind"] != "object",
                    name,
                ),
            )
            components.append(members)
            for member in members:
                component_for[member] = new_id
        return components, component_for

    def _codec_closures(self) -> tuple[set[str], set[str]]:
        def closure(roots: Iterable[Mapping[str, Any]]) -> set[str]:
            found: set[str] = set()
            pending = list(roots)
            while pending:
                expression = pending.pop()
                named = self._model_for(expression)
                if named is not None and expression is not self.models[named].expression:
                    # A reference: continue at the referenced definition.
                    if named not in found:
                        found.add(named)
                        pending.append(self.models[named].expression)
                    continue
                if named is not None and named not in found:
                    found.add(named)
                pending.extend(_child_expressions(expression))
            return found

        read_roots: list[Mapping[str, Any]] = []
        write_roots: list[Mapping[str, Any]] = []
        for wire_name in self.allowlist.commands:
            command = self.ir.command(wire_name)
            write_roots.append(command["request"])
            read_roots.append(command["result"])
        for wire_name in self.allowlist.events:
            read_roots.append(self.ir.event(wire_name)["payload"])
        return closure(read_roots), closure(write_roots)

    # -- C++ types ------------------------------------------------------------

    def _is_struct(self, name: str) -> bool:
        return self.models[name].expression["kind"] in _STRUCT_KINDS

    def _needs_pointer(self, target: str, owner: str | None, context: str) -> bool:
        if owner is None or not self._is_struct(target):
            return False
        if self.component_for.get(target) != self.component_for.get(owner):
            return False
        if context == "vector":
            return False
        if context == "variant":
            return self.models[target].expression["kind"] != "object"
        return True

    def cpp_type(
        self,
        expression: Mapping[str, Any],
        owner: str | None,
        context: str = "member",
    ) -> str:
        """Return the C++ type of ``expression`` as used inside ``owner``.

        ``context`` is ``member`` (a struct field), ``vector`` (an array
        item), ``map`` (a map value), ``variant`` (a union alternative) or
        ``top`` (a public alias).
        """

        kind = expression["kind"]
        named = self._model_for(expression)
        if named is not None:
            if self._needs_pointer(named, owner, context):
                return f"std::unique_ptr<{named}>"
            return named
        if kind == "scalar":
            return _SCALAR_TYPES[str(expression["name"])]
        if kind == "literal":
            return _literal_cpp_type(expression["value"])
        if kind == "ref":
            name = cpp_type_name(str(expression["name"]))
            if name in self.aliases:
                return name
            raise GenerationError(f"unresolved type reference {name}")
        if kind == "array":
            return f"std::vector<{self.cpp_type(expression['items'], owner, 'vector')}>"
        if kind == "map":
            value = self.cpp_type(expression["values"], owner, "map")
            return f"std::map<std::string, {value}>"
        if kind == "opaque_json":
            return "base::Value"
        if kind == "alias":
            return self.cpp_type(expression["target"], owner, context)
        raise GenerationError(f"unnamed inline {kind} type in {owner}")

    def _resolved(self, expression: Mapping[str, Any]) -> Mapping[str, Any]:
        """Follow references and aliases to the defining expression."""

        seen: set[str] = set()
        while True:
            kind = expression["kind"]
            if kind == "alias":
                expression = expression["target"]
            elif kind == "ref":
                name = str(expression["name"])
                if name in seen:
                    return expression
                seen.add(name)
                expression = self.ir.type(name)
            else:
                return expression

    def _member_default(self, expression: Mapping[str, Any], cpp_type: str) -> str | None:
        if cpp_type.startswith("std::unique_ptr<"):
            return None
        resolved = self._resolved(expression)
        if resolved["kind"] == "scalar":
            return _SCALAR_DEFAULTS[str(resolved["name"])]
        if resolved["kind"] == "literal":
            value = resolved["value"]
            if isinstance(value, bool):
                return "false"
            return None
        if resolved["kind"] == "enum":
            return f"{cpp_type}::kUnknown"
        return None

    def _field_shape(
        self, owner: str, field: Mapping[str, Any]
    ) -> tuple[str, str | None, str | None]:
        """Return (shape, member C++ type, default initializer).

        Shapes: ``constant`` (a required, non-null literal; no member),
        ``plain``, ``optional`` (``std::optional``), ``tristate``
        (``OptionalNullable``: an optional, nullable field of a type that is
        encoded) and ``pointer`` (``std::unique_ptr``; null means absent).
        """

        expression = field["type"]
        optional = field["presence"] == "optional"
        nullable = bool(field["nullable"])
        if expression["kind"] == "literal" and not optional and not nullable:
            return "constant", None, None
        base = self.cpp_type(expression, owner, "member")
        tristate = optional and nullable and owner in self.write_models
        if base.startswith("std::unique_ptr<"):
            if tristate:
                raise GenerationError(
                    f"{owner}: an optional, nullable field that holds a recursive "
                    "type is not supported in an encoded type"
                )
            return "pointer", base, None
        if tristate:
            return "tristate", f"OptionalNullable<{base}>", None
        if optional or nullable:
            return "optional", f"std::optional<{base}>", None
        return "plain", base, self._member_default(expression, base)

    # -- header -----------------------------------------------------------------

    def _enum_entries(self, expression: Mapping[str, Any]) -> list[tuple[str, str]]:
        """Return (wire value, enumerator) pairs; ``kUnknown`` is reserved."""

        used = {"kUnknown"}
        entries: list[tuple[str, str]] = []
        for value in expression["values"]:
            enumerator = cpp_enumerator(str(value))
            if enumerator == "kUnknown" and str(value) == "unknown":
                entries.append((str(value), "kUnknown"))
                continue
            candidate = enumerator
            index = 2
            while candidate in used:
                candidate = f"{enumerator}{index}"
                index += 1
            used.add(candidate)
            entries.append((str(value), candidate))
        return entries

    def _enum_fallback(self, expression: Mapping[str, Any]) -> str:
        if "fallback" not in expression:
            return "kUnknown"
        fallback = str(expression["fallback"])
        for value, enumerator in self._enum_entries(expression):
            if value == fallback:
                return enumerator
        raise GenerationError(f"enum fallback {fallback!r} is not one of its values")

    def _enum_definition(self, model: _Model) -> list[str]:
        lines = [f"enum class {model.name} {{", "  kUnknown,"]
        for value, enumerator in self._enum_entries(model.expression):
            if enumerator == "kUnknown":
                continue
            lines.append(f"  {enumerator},  // {cpp_string(value)}")
        lines.append("};")
        return lines

    def _union_alternatives(self, model: _Model) -> list[tuple[str | None, str]]:
        expression = model.expression
        if expression["kind"] == "tagged_union":
            return [
                (str(tag), self.cpp_type(variant, model.name, "variant"))
                for tag, variant in expression["variants"].items()
            ]
        return [
            (None, self.cpp_type(variant, model.name, "variant"))
            for variant in expression["variants"]
        ]

    def _struct_definition(self, model: _Model) -> list[str]:
        expression = model.expression
        lines: list[str] = []
        if model.origin == "params":
            lines.append(f"// Parameters of {cpp_string(str(model.wire_name))}.")
        elif model.origin == "result":
            lines.append(f"// Result of {cpp_string(str(model.wire_name))}.")
        elif model.origin == "event":
            lines.append(f"// Payload of the event {cpp_string(str(model.wire_name))}.")
        elif model.origin == "named":
            lines.append(f"// Spec type {model.wire_name}.")
        if expression["kind"] in {"tagged_union", "untagged_union"}:
            alternatives = self._union_alternatives(model)
            if expression["kind"] == "tagged_union":
                tags = ", ".join(cpp_string(tag or "") for tag, _ in alternatives)
                lines.append(
                    f"// Tagged by {cpp_string(str(expression['tag']))}: {tags}."
                )
            lines.extend(
                [
                    f"struct {model.name} {{",
                    "  std::variant<"
                    + ", ".join(cpp for _, cpp in alternatives)
                    + "> value;",
                    "};",
                ]
            )
            return lines
        if not expression["fields"] and not expression["additional_properties"]:
            lines.append(f"struct {model.name} {{}};")
            return lines
        lines.append(f"struct {model.name} {{")
        members: dict[str, str] = {}
        if expression["additional_properties"]:
            members["additional_properties"] = "(extra properties)"
        for wire_name, field in expression["fields"].items():
            shape, member_type, default = self._field_shape(model.name, field)
            if shape != "constant":
                member_name = cpp_field_name(wire_name)
                if member_name in members:
                    raise GenerationError(
                        f"{model.name}: wire fields {members[member_name]!r} and "
                        f"{wire_name!r} both map to the C++ member {member_name}"
                    )
                members[member_name] = str(wire_name)
            if shape == "constant":
                continue
            notes: list[str] = []
            if wire_name != cpp_field_name(wire_name):
                notes.append(f"wire {cpp_string(str(wire_name))}")
            if "since" in field:
                notes.append(f"since {field['since']}")
            if "capability" in field:
                notes.append(f"capability {cpp_string(str(field['capability']))}")
            if notes:
                lines.append(f"  // {', '.join(notes)}")
            initializer = f" = {default}" if default is not None else ""
            lines.append(f"  {member_type} {cpp_field_name(wire_name)}{initializer};")
        if expression["additional_properties"]:
            lines.append("  // Fields that the spec does not name.")
            lines.append("  base::DictValue additional_properties;")
        lines.append("};")
        return lines

    def header(self) -> str:
        guard = include_guard(self.include_path)
        lines = [
            "// Generated by cmux-tui/bindings/codegen/emit_cpp_value.py from",
            "// cmux-tui/spec/sdk-schema.json. Do not edit.",
            f"// Spec IR SHA-256: {self.ir.ir_sha256}",
            f"// Allowlist SHA-256: {self.allowlist.digest()}",
            "",
            f"#ifndef {guard}",
            f"#define {guard}",
            "",
            "#include <stdint.h>",
            "",
            "#include <map>",
            "#include <memory>",
            "#include <optional>",
            "#include <string>",
            "#include <string_view>",
            "#include <utility>",
            "#include <variant>",
            "#include <vector>",
            "",
            '#include "base/types/expected.h"',
            '#include "base/values.h"',
            "",
            "namespace cmux::daemon {",
            "",
            f"inline constexpr int kMuxProtocolVersion = {int(self.ir.mux_protocol)};",
            f"inline constexpr std::string_view kSpecIrSha256 =\n    {cpp_string(self.ir.ir_sha256)};",
            "",
            "// A decode failure. `path` names the value, for example",
            '// "result.panes[2].id"; `message` says what is wrong with it.',
            "struct DecodeError {",
            "  std::string path;",
            "  std::string message;",
            "};",
            "",
            "// A request field that the spec makes optional and nullable. The daemon",
            "// reads an absent key and an explicit null as different requests (for",
            "// example, null clears a tab's profile; an absent key keeps it).",
            "// `value` set: the value is sent. Else `is_null`: null is sent. Else the",
            "// key is absent.",
            "template <typename T>",
            "struct OptionalNullable {",
            "  static OptionalNullable Null() {",
            "    OptionalNullable field;",
            "    field.is_null = true;",
            "    return field;",
            "  }",
            "  static OptionalNullable Of(T item) {",
            "    OptionalNullable field;",
            "    field.value = std::move(item);",
            "    return field;",
            "  }",
            "  bool is_absent() const { return !value.has_value() && !is_null; }",
            "",
            "  std::optional<T> value;",
            "  bool is_null = false;",
            "};",
            "",
        ]
        if self.aliases:
            for name in sorted(self.aliases):
                lines.append(f"using {name} = {self.aliases[name]};")
            lines.append("")
        enums = [
            model for model in self.models.values() if model.expression["kind"] == "enum"
        ]
        for model in sorted(enums, key=lambda value: value.name):
            if model.origin == "named":
                lines.append(f"// Spec type {model.wire_name}.")
            fallback = self._enum_fallback(model.expression)
            lines.append(
                "// An unknown string decodes to "
                f"{model.name}::{fallback}."
            )
            lines.extend(self._enum_definition(model))
            lines.append("")
        structs = [name for component in self.components for name in component
                   if self._is_struct(name)]
        if structs:
            for name in sorted(structs):
                lines.append(f"struct {name};")
            lines.append("")
            for name in structs:
                lines.extend(self._struct_definition(self.models[name]))
                lines.append("")

        for wire_name in self.allowlist.commands:
            lines.extend(self._command_declarations(wire_name))
            lines.append("")

        lines.extend(
            [
                "// An event that this allowlist does not name, or whose payload did not",
                "// decode. `payload` is the whole event object.",
                "struct UnknownEvent {",
                "  std::string name;",
                "  base::DictValue payload;",
                "};",
                "",
            ]
        )
        for wire_name in self.allowlist.events:
            event = self.ir.event(wire_name)
            base = cpp_type_name(wire_name)
            capability = event["capability"]
            lines.extend(
                [
                    f"inline constexpr std::string_view k{base}EventName = "
                    f"{cpp_string(wire_name)};",
                    f"inline constexpr std::string_view k{base}EventCapability = "
                    f"{cpp_string('' if capability is None else str(capability))};",
                    f"inline constexpr int k{base}EventSince = {int(event['since'])};",
                ]
            )
        if self.allowlist.events:
            lines.append("")
        event_types = ["UnknownEvent", *(
            self.event_names[wire_name] for wire_name in self.allowlist.events
        )]
        lines.extend(
            [
                f"using Event = std::variant<{', '.join(event_types)}>;",
                "",
                "// Decodes one event object ({\"event\": NAME, ...fields}). An event that",
                "// is not in the allowlist gives UnknownEvent; a payload that does not",
                "// decode gives a DecodeError.",
                "base::expected<Event, DecodeError> DecodeEventChecked(",
                "    const base::DictValue& event);",
                "",
                "// Like DecodeEventChecked(), but never fails: a payload that does not",
                "// decode gives UnknownEvent.",
                "Event DecodeEvent(const base::DictValue& event);",
                "",
                "}  // namespace cmux::daemon",
                "",
                f"#endif  // {guard}",
                "",
            ]
        )
        return "\n".join(lines)

    def _command_declarations(self, wire_name: str) -> list[str]:
        command = self.ir.command(wire_name)
        base = cpp_type_name(wire_name)
        params = self.params_names[wire_name]
        result = self.result_types[wire_name]
        capability = command["capability"]
        stream = command["stream"]
        lines = [f"// Command {cpp_string(wire_name)} ({command['authority']})."]
        if stream is not None:
            lines.append(
                f"// Opens a {stream['kind']} stream; events arrive through "
                "DecodeEvent()."
            )
        lines.extend(
            [
                f"inline constexpr std::string_view k{base}Method = {cpp_string(wire_name)};",
                f"inline constexpr std::string_view k{base}Capability = "
                f"{cpp_string('' if capability is None else str(capability))};",
                f"inline constexpr int k{base}Since = {int(command['since'])};",
            ]
        )
        if wire_name in self.result_aliases:
            target = self.cpp_type(command["result"], None, "top")
            if target != result:
                lines.append(f"using {result} = {target};")
        lines.extend(
            [
                f"base::DictValue Encode(const {params}& params);",
                f"base::expected<{result}, DecodeError> Decode{base}Result(",
                "    const base::Value& result);",
            ]
        )
        return lines

    # -- source -----------------------------------------------------------------

    def _read_declarations(self, name: str) -> list[str]:
        model = self.models[name]
        lines = [
            "[[maybe_unused]] bool ReadModel(const base::Value& value,",
            f"                               DecodeContext& context, {name}& out);",
        ]
        if model.expression["kind"] == "object":
            lines.extend(
                [
                    "[[maybe_unused]] bool ReadObject(const base::DictValue& dict,",
                    f"                                DecodeContext& context, {name}& out);",
                ]
            )
        return lines

    def _write_declarations(self, name: str) -> list[str]:
        model = self.models[name]
        lines = [f"[[maybe_unused]] base::Value WriteModel(const {name}& in);"]
        if model.expression["kind"] == "object":
            lines.append(f"[[maybe_unused]] base::DictValue WriteObject(const {name}& in);")
        return lines

    def _known_keys(self, model: _Model) -> list[str]:
        keys = {str(wire_name) for wire_name in model.expression["fields"]}
        for field in model.expression["fields"].values():
            keys.update(str(alias) for alias in field.get("aliases", ()))
        if model.origin == "event":
            keys.add("event")
        return sorted(keys)

    def _read_field(self, model: _Model, wire_name: str, field: Mapping[str, Any]) -> list[str]:
        shape, _, _ = self._field_shape(model.name, field)
        member = f"out.{cpp_field_name(wire_name)}"
        expression = field["type"]
        optional = field["presence"] == "optional"
        lines = [
            "  {",
            f"    const size_t mark = PushField(context, {cpp_string(wire_name)});",
            f"    const base::Value* field = dict.Find({cpp_string(wire_name)});",
        ]
        for alias in field.get("aliases", ()):
            lines.extend(
                [
                    "    if (!field) {",
                    f"      field = dict.Find({cpp_string(str(alias))});",
                    "    }",
                ]
            )
        if not optional:
            lines.extend(
                [
                    "    if (!field) {",
                    '      return Fail(context, "missing required field");',
                    "    }",
                ]
            )
        if shape == "constant":
            literal = expression["value"]
            lines.extend(
                [
                    f"    if ({_literal_mismatch('field', literal)}) {{",
                    f"      return Fail(context, {cpp_string('expected ' + json.dumps(literal))});",
                    "    }",
                ]
            )
        elif shape == "tristate" and expression["kind"] == "literal":
            literal = expression["value"]
            lines.extend(
                [
                    "    if (field && field->is_none()) {",
                    f"      {member}.is_null = true;",
                    "    } else if (field) {",
                    f"      if ({_literal_mismatch('field', literal)}) {{",
                    f"        return Fail(context, {cpp_string('expected ' + json.dumps(literal))});",
                    "      }",
                    f"      {member}.value = {_literal_cpp_value(literal)};",
                    "    }",
                ]
            )
        elif shape == "tristate":
            lines.extend(
                [
                    "    if (field && field->is_none()) {",
                    f"      {member}.is_null = true;",
                    "    } else if (field) {",
                    f"      {member}.value.emplace();",
                    f"      if (!ReadValue(*field, context, *{member}.value)) {{",
                    "        return false;",
                    "      }",
                    "    }",
                ]
            )
        elif expression["kind"] == "literal":
            # An optional or nullable literal: std::optional of its C++ type.
            literal = expression["value"]
            guard = "field && !field->is_none()" if optional else "!field->is_none()"
            lines.extend(
                [
                    f"    if ({guard}) {{",
                    f"      if ({_literal_mismatch('field', literal)}) {{",
                    f"        return Fail(context, {cpp_string('expected ' + json.dumps(literal))});",
                    "      }",
                    f"      {member} = {_literal_cpp_value(literal)};",
                    "    }",
                ]
            )
        elif shape == "plain":
            lines.extend(
                [
                    f"    if (!ReadValue(*field, context, {member})) {{",
                    "      return false;",
                    "    }",
                ]
            )
        elif shape == "optional":
            guard = "field && !field->is_none()" if optional else "!field->is_none()"
            lines.extend(
                [
                    f"    if ({guard}) {{",
                    f"      {member}.emplace();",
                    f"      if (!ReadValue(*field, context, *{member})) {{",
                    "        return false;",
                    "      }",
                    "    }",
                ]
            )
        elif shape == "pointer":
            nullable = bool(field["nullable"])
            if optional or nullable:
                guard = "field && !field->is_none()" if optional else "!field->is_none()"
                lines.extend(
                    [
                        f"    if ({guard}) {{",
                        f"      if (!ReadValue(*field, context, {member})) {{",
                        "        return false;",
                        "      }",
                        "    }",
                    ]
                )
            else:
                lines.extend(
                    [
                        f"    if (!ReadValue(*field, context, {member})) {{",
                        "      return false;",
                        "    }",
                    ]
                )
        else:  # pragma: no cover - shapes are closed
            raise GenerationError(f"unknown field shape {shape}")
        lines.extend(["    PopPath(context, mark);", "  }"])
        return lines

    def _write_field(self, model: _Model, wire_name: str, field: Mapping[str, Any]) -> list[str]:
        shape, _, _ = self._field_shape(model.name, field)
        member = f"in.{cpp_field_name(wire_name)}"
        key = cpp_string(wire_name)
        expression = field["type"]
        optional = field["presence"] == "optional"
        if shape == "constant":
            return [f"  dict.Set({key}, {_literal_value_expression(expression['value'])});"]
        if shape == "tristate":
            value = (
                _literal_value_expression(expression["value"])
                if expression["kind"] == "literal"
                else f"WriteValue(*{member}.value)"
            )
            return [
                f"  if ({member}.value) {{",
                f"    dict.Set({key}, {value});",
                f"  }} else if ({member}.is_null) {{",
                f"    dict.Set({key}, base::Value());",
                "  }",
            ]
        if expression["kind"] == "literal":
            value = _literal_value_expression(expression["value"])
            if optional:
                return [f"  if ({member}) {{", f"    dict.Set({key}, {value});", "  }"]
            return [f"  dict.Set({key}, {member} ? {value} : base::Value());"]
        if shape == "plain":
            return [f"  dict.Set({key}, WriteValue({member}));"]
        # Optional and pointer shapes: an empty value is absent (optional) or
        # null (required nullable).
        if optional:
            return [
                f"  if ({member}) {{",
                f"    dict.Set({key}, WriteValue(*{member}));",
                "  }",
            ]
        return [f"  dict.Set({key}, {member} ? WriteValue(*{member}) : base::Value());"]

    def _object_codec(self, model: _Model) -> list[str]:
        expression = model.expression
        fields = list(expression["fields"].items())
        extra = bool(expression["additional_properties"])
        lines: list[str] = []
        if model.name in self.read_models:
            has_body = bool(fields) or extra
            dict_name = "dict" if has_body else "/*dict*/"
            context_name = "context" if fields else "/*context*/"
            out_name = "out" if has_body else "/*out*/"
            lines.extend(
                [
                    f"bool ReadObject(const base::DictValue& {dict_name},",
                    f"                DecodeContext& {context_name}, {model.name}& {out_name}) {{",
                ]
            )
            for wire_name, field in fields:
                lines.extend(self._read_field(model, str(wire_name), field))
            if extra:
                keys = self._known_keys(model)
                lines.append("  for (const auto [key, item] : dict) {")
                if keys:
                    condition = " || ".join(f"key == {cpp_string(key)}" for key in keys)
                    lines.extend([f"    if ({condition}) {{", "      continue;", "    }"])
                lines.extend(
                    ["    out.additional_properties.Set(key, item.Clone());", "  }"]
                )
            lines.extend(
                [
                    "  return true;",
                    "}",
                    "",
                    f"bool ReadModel(const base::Value& value, DecodeContext& context,",
                    f"               {model.name}& out) {{",
                    "  const base::DictValue* dict = value.GetIfDict();",
                    "  if (!dict) {",
                    '    return Fail(context, "expected an object");',
                    "  }",
                    "  return ReadObject(*dict, context, out);",
                    "}",
                    "",
                ]
            )
        if model.name in self.write_models:
            in_name = "in" if fields or extra else "/*in*/"
            lines.extend(
                [
                    f"base::DictValue WriteObject(const {model.name}& {in_name}) {{",
                    "  base::DictValue dict;",
                ]
            )
            for wire_name, field in fields:
                lines.extend(self._write_field(model, str(wire_name), field))
            if extra:
                lines.extend(
                    [
                        "  for (const auto [key, item] : in.additional_properties) {",
                        "    if (!dict.contains(key)) {",
                        "      dict.Set(key, item.Clone());",
                        "    }",
                        "  }",
                    ]
                )
            lines.extend(
                [
                    "  return dict;",
                    "}",
                    "",
                    f"base::Value WriteModel(const {model.name}& in) {{",
                    "  return base::Value(WriteObject(in));",
                    "}",
                    "",
                ]
            )
        return lines

    def _enum_codec(self, model: _Model) -> list[str]:
        entries = self._enum_entries(model.expression)
        fallback = self._enum_fallback(model.expression)
        lines: list[str] = []
        if model.name in self.read_models:
            lines.extend(
                [
                    f"bool ReadModel(const base::Value& value, DecodeContext& context,",
                    f"               {model.name}& out) {{",
                    "  const std::string* text = value.GetIfString();",
                    "  if (!text) {",
                    '    return Fail(context, "expected a string");',
                    "  }",
                ]
            )
            for value, enumerator in entries:
                lines.extend(
                    [
                        f"  if (*text == {cpp_string(value)}) {{",
                        f"    out = {model.name}::{enumerator};",
                        "    return true;",
                        "  }",
                    ]
                )
            lines.extend(
                [
                    f"  out = {model.name}::{fallback};",
                    "  return true;",
                    "}",
                    "",
                ]
            )
        if model.name in self.write_models:
            has_unknown_value = any(enumerator == "kUnknown" for _, enumerator in entries)
            lines.extend(
                [
                    f"base::Value WriteModel(const {model.name}& in) {{",
                    "  switch (in) {",
                ]
            )
            if not has_unknown_value:
                lines.extend(
                    [
                        f"    case {model.name}::kUnknown:",
                        "      // No wire value; the daemon rejects null where it needs one.",
                        "      return base::Value();",
                    ]
                )
            for value, enumerator in entries:
                lines.extend(
                    [
                        f"    case {model.name}::{enumerator}:",
                        f"      return base::Value({cpp_string(value)});",
                    ]
                )
            lines.extend(["  }", "  return base::Value();", "}", ""])
        return lines

    def _union_codec(self, model: _Model) -> list[str]:
        expression = model.expression
        alternatives = self._union_alternatives(model)
        lines: list[str] = []
        if model.name in self.read_models:
            lines.extend(
                [
                    f"bool ReadModel(const base::Value& value, DecodeContext& context,",
                    f"               {model.name}& out) {{",
                ]
            )
            if expression["kind"] == "tagged_union":
                tag = cpp_string(str(expression["tag"]))
                lines.extend(
                    [
                        "  const base::DictValue* dict = value.GetIfDict();",
                        "  if (!dict) {",
                        '    return Fail(context, "expected an object");',
                        "  }",
                        f"  const std::string* tag = dict->FindString({tag});",
                        "  if (!tag) {",
                        f"    PushField(context, {tag});",
                        '    return Fail(context, "missing union tag");',
                        "  }",
                    ]
                )
                for index, (variant_tag, _) in enumerate(alternatives):
                    lines.extend(
                        [
                            f"  if (*tag == {cpp_string(str(variant_tag))}) {{",
                            f"    return ReadValue(value, context, out.value.emplace<{index}>());",
                            "  }",
                        ]
                    )
                lines.extend(
                    [
                        f"  PushField(context, {tag});",
                        '  return Fail(context, "unknown union tag \\"" + *tag + "\\"");',
                        "}",
                        "",
                    ]
                )
            else:
                lines.append("  const size_t mark = context.path.size();")
                for index, _ in enumerate(alternatives):
                    lines.extend(
                        [
                            f"  if (ReadValue(value, context, out.value.emplace<{index}>())) {{",
                            "    return true;",
                            "  }",
                            "  PopPath(context, mark);",
                        ]
                    )
                lines.extend(
                    [
                        f'  return Fail(context, "matches no variant of {model.name}");',
                        "}",
                        "",
                    ]
                )
        if model.name in self.write_models:
            lines.extend(
                [
                    f"base::Value WriteModel(const {model.name}& in) {{",
                    "  switch (in.value.index()) {",
                ]
            )
            for index, (variant_tag, _) in enumerate(alternatives):
                if expression["kind"] == "tagged_union":
                    tag = cpp_string(str(expression["tag"]))
                    lines.extend(
                        [
                            f"    case {index}: {{",
                            f"      base::Value result = WriteValue(std::get<{index}>(in.value));",
                            "      if (base::DictValue* dict = result.GetIfDict()) {",
                            f"        dict->Set({tag}, {cpp_string(str(variant_tag))});",
                            "      }",
                            "      return result;",
                            "    }",
                        ]
                    )
                else:
                    lines.extend(
                        [
                            f"    case {index}:",
                            f"      return WriteValue(std::get<{index}>(in.value));",
                        ]
                    )
            lines.extend(["  }", "  return base::Value();", "}", ""])
        return lines

    def source(self) -> str:
        lines = [
            "// Generated by cmux-tui/bindings/codegen/emit_cpp_value.py from",
            "// cmux-tui/spec/sdk-schema.json. Do not edit.",
            f"// Spec IR SHA-256: {self.ir.ir_sha256}",
            f"// Allowlist SHA-256: {self.allowlist.digest()}",
            "",
            f'#include "{self.include_path}"',
            "",
            "#include <stddef.h>",
            "#include <stdint.h>",
            "",
            "#include <cmath>",
            "#include <optional>",
            "#include <string>",
            "#include <string_view>",
            "#include <type_traits>",
            "#include <utility>",
            "",
            '#include "base/check_op.h"',
            '#include "base/numerics/safe_conversions.h"',
            '#include "base/strings/string_number_conversions.h"',
            "",
            "namespace cmux::daemon {",
            "",
            "namespace {",
            "",
            _SOURCE_PRELUDE,
        ]
        ordered = [
            name
            for component in self.components
            for name in component
            if self._is_struct(name)
        ]
        enum_names = sorted(
            name for name, model in self.models.items()
            if model.expression["kind"] == "enum"
        )
        all_names = enum_names + ordered
        declarations: list[str] = []
        for name in all_names:
            if name in self.read_models:
                declarations.extend(self._read_declarations(name))
            if name in self.write_models:
                declarations.extend(self._write_declarations(name))
        if declarations:
            lines.extend(declarations)
            lines.append("")
        lines.append(_SOURCE_TEMPLATES)
        for name in all_names:
            model = self.models[name]
            kind = model.expression["kind"]
            if kind == "object":
                lines.extend(self._object_codec(model))
            elif kind == "enum":
                lines.extend(self._enum_codec(model))
            else:
                lines.extend(self._union_codec(model))
        lines.extend(["}  // namespace", ""])

        for wire_name in self.allowlist.commands:
            base = cpp_type_name(wire_name)
            params = self.params_names[wire_name]
            result = self.result_types[wire_name]
            lines.extend(
                [
                    f"base::DictValue Encode(const {params}& params) {{",
                    "  return WriteObject(params);",
                    "}",
                    "",
                    f"base::expected<{result}, DecodeError> Decode{base}Result(",
                    "    const base::Value& result) {",
                    "  DecodeContext context;",
                    '  context.path = "result";',
                    f"  {result} decoded{{}};",
                    "  if (!ReadValue(result, context, decoded)) {",
                    "    return base::unexpected(",
                    "        DecodeError{std::move(context.path), std::move(context.message)});",
                    "  }",
                    "  return decoded;",
                    "}",
                    "",
                ]
            )

        lines.extend(
            [
                "base::expected<Event, DecodeError> DecodeEventChecked(",
                "    const base::DictValue& event) {",
                '  const std::string* name = event.FindString("event");',
                "  if (!name) {",
                "    return base::unexpected(",
                '        DecodeError{"event.event", "missing event name"});',
                "  }",
            ]
        )
        if self.allowlist.events:
            lines.extend(["  DecodeContext context;", '  context.path = "event";'])
        for wire_name in self.allowlist.events:
            base = cpp_type_name(wire_name)
            model = self.event_names[wire_name]
            lines.extend(
                [
                    f"  if (*name == k{base}EventName) {{",
                    f"    {model} decoded;",
                    "    if (!ReadObject(event, context, decoded)) {",
                    "      return base::unexpected(DecodeError{std::move(context.path),",
                    "                                          std::move(context.message)});",
                    "    }",
                    f"    return Event(std::in_place_type<{model}>, std::move(decoded));",
                    "  }",
                ]
            )
        lines.extend(
            [
                "  return Event(std::in_place_type<UnknownEvent>,",
                "               UnknownEvent{*name, event.Clone()});",
                "}",
                "",
                "Event DecodeEvent(const base::DictValue& event) {",
                "  base::expected<Event, DecodeError> decoded = DecodeEventChecked(event);",
                "  if (decoded.has_value()) {",
                "    return std::move(decoded).value();",
                "  }",
                '  const std::string* name = event.FindString("event");',
                "  return Event(std::in_place_type<UnknownEvent>,",
                "               UnknownEvent{name ? *name : std::string(), event.Clone()});",
                "}",
                "",
                "}  // namespace cmux::daemon",
                "",
            ]
        )
        return "\n".join(lines)

    def render(self) -> dict[str, str]:
        return {HEADER_NAME: self.header(), SOURCE_NAME: self.source()}


# ---------------------------------------------------------------------------
# Fixed C++ text


_SOURCE_PRELUDE = """\
// Every integer below this magnitude has an exact double (2^53). 2^53 + 1
// reads as 2^53, so 2^53 itself is refused too.
constexpr double kMaxExactInteger = 9007199254740992.0;

// The path of the value being decoded and, after a failure, the message.
// The path grows and shrinks as the decoder walks the value, so a failure
// leaves it at the failing value.
struct DecodeContext {
  std::string path;
  std::string message;
};

template <typename T>
struct IsVector : std::false_type {};
template <typename T>
struct IsVector<std::vector<T>> : std::true_type {};

template <typename T>
struct IsStringMap : std::false_type {};
template <typename T>
struct IsStringMap<std::map<std::string, T>> : std::true_type {};

template <typename T>
struct IsUniquePtr : std::false_type {};
template <typename T>
struct IsUniquePtr<std::unique_ptr<T>> : std::true_type {};

[[maybe_unused]] bool Fail(DecodeContext& context, std::string message) {
  context.message = std::move(message);
  return false;
}

[[maybe_unused]] size_t PushField(DecodeContext& context, std::string_view key) {
  const size_t mark = context.path.size();
  context.path.push_back('.');
  context.path.append(key);
  return mark;
}

[[maybe_unused]] size_t PushIndex(DecodeContext& context, size_t index) {
  const size_t mark = context.path.size();
  context.path.push_back('[');
  context.path.append(base::NumberToString(index));
  context.path.push_back(']');
  return mark;
}

[[maybe_unused]] void PopPath(DecodeContext& context, size_t mark) {
  context.path.resize(mark);
}

// base::Value holds an int (32 bits) or a double. The JSON reader gives a
// double for an integer outside the int range.
template <typename T>
bool ReadInteger(const base::Value& value, DecodeContext& context, T& out) {
  int64_t wide = 0;
  if (std::optional<int> integer = value.GetIfInt()) {
    wide = *integer;
  } else if (value.is_double()) {
    const double number = value.GetDouble();
    if (!std::isfinite(number) || std::trunc(number) != number) {
      return Fail(context, "expected an integer");
    }
    if (std::fabs(number) >= kMaxExactInteger) {
      return Fail(context, "integer at or above 2^53 has no exact value");
    }
    wide = static_cast<int64_t>(number);
  } else {
    return Fail(context, "expected an integer");
  }
  if (!base::IsValueInRangeForNumericType<T>(wide)) {
    return Fail(context, "integer out of range");
  }
  out = static_cast<T>(wide);
  return true;
}

template <typename T>
base::Value WriteInteger(T value) {
  if (base::IsValueInRangeForNumericType<int>(value)) {
    return base::Value(static_cast<int>(value));
  }
  const double number = static_cast<double>(value);
  // At or above 2^53 the wire value is not exact. Protocol ids stay below
  // it; a larger value is a bug, never a rounded id on the wire.
  CHECK_LT(std::fabs(number), kMaxExactInteger);
  return base::Value(number);
}
"""

_SOURCE_TEMPLATES = """\
template <typename T>
bool ReadValue(const base::Value& value, DecodeContext& context, T& out) {
  if constexpr (std::is_same_v<T, std::string>) {
    const std::string* text = value.GetIfString();
    if (!text) {
      return Fail(context, "expected a string");
    }
    out = *text;
    return true;
  } else if constexpr (std::is_same_v<T, bool>) {
    std::optional<bool> flag = value.GetIfBool();
    if (!flag) {
      return Fail(context, "expected a boolean");
    }
    out = *flag;
    return true;
  } else if constexpr (std::is_integral_v<T>) {
    return ReadInteger(value, context, out);
  } else if constexpr (std::is_floating_point_v<T>) {
    std::optional<double> number = value.GetIfDouble();
    if (!number) {
      return Fail(context, "expected a number");
    }
    out = static_cast<T>(*number);
    return true;
  } else if constexpr (std::is_same_v<T, base::Value>) {
    out = value.Clone();
    return true;
  } else if constexpr (IsVector<T>::value) {
    const base::ListValue* list = value.GetIfList();
    if (!list) {
      return Fail(context, "expected an array");
    }
    out.clear();
    out.reserve(list->size());
    size_t index = 0;
    for (const base::Value& item : *list) {
      const size_t mark = PushIndex(context, index);
      typename T::value_type decoded{};
      if (!ReadValue(item, context, decoded)) {
        return false;
      }
      out.push_back(std::move(decoded));
      PopPath(context, mark);
      ++index;
    }
    return true;
  } else if constexpr (IsStringMap<T>::value) {
    const base::DictValue* dict = value.GetIfDict();
    if (!dict) {
      return Fail(context, "expected an object");
    }
    out.clear();
    for (const auto [key, item] : *dict) {
      const size_t mark = PushField(context, key);
      typename T::mapped_type decoded{};
      if (!ReadValue(item, context, decoded)) {
        return false;
      }
      out.emplace(key, std::move(decoded));
      PopPath(context, mark);
    }
    return true;
  } else if constexpr (IsUniquePtr<T>::value) {
    auto decoded = std::make_unique<typename T::element_type>();
    if (!ReadValue(value, context, *decoded)) {
      return false;
    }
    out = std::move(decoded);
    return true;
  } else {
    return ReadModel(value, context, out);
  }
}

template <typename T>
base::Value WriteValue(const T& in) {
  if constexpr (std::is_same_v<T, std::string>) {
    return base::Value(in);
  } else if constexpr (std::is_same_v<T, bool>) {
    return base::Value(in);
  } else if constexpr (std::is_integral_v<T>) {
    return WriteInteger(in);
  } else if constexpr (std::is_floating_point_v<T>) {
    return base::Value(static_cast<double>(in));
  } else if constexpr (std::is_same_v<T, base::Value>) {
    return in.Clone();
  } else if constexpr (IsVector<T>::value) {
    base::ListValue list;
    list.reserve(in.size());
    for (const auto& item : in) {
      // The explicit type also reads a std::vector<bool> bit reference.
      list.Append(WriteValue<typename T::value_type>(item));
    }
    return base::Value(std::move(list));
  } else if constexpr (IsStringMap<T>::value) {
    base::DictValue dict;
    for (const auto& [key, item] : in) {
      dict.Set(key, WriteValue(item));
    }
    return base::Value(std::move(dict));
  } else if constexpr (IsUniquePtr<T>::value) {
    return in ? WriteValue(*in) : base::Value();
  } else {
    return WriteModel(in);
  }
}
"""


# ---------------------------------------------------------------------------
# Literals and expression walking


def _check_literal(value: Any, *, where: str) -> None:
    if value is not None and not isinstance(value, (str, bool, int, float)):
        raise GenerationError(f"{where}: unsupported literal {value!r}")


def _number_text(value: int | float) -> str:
    """A C++ double literal for a JSON number."""

    text = repr(float(value))
    return text if any(mark in text for mark in ".en") else f"{text}.0"


def _literal_cpp_type(value: Any) -> str:
    _check_literal(value, where="literal")
    if value is None:
        return "base::Value"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int64_t" if value < 0 else "uint64_t"
    if isinstance(value, float):
        return "double"
    return "std::string"


def _literal_cpp_value(value: Any) -> str:
    _check_literal(value, where="literal")
    if value is None:
        return "base::Value()"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        if value < 0:
            return f"static_cast<int64_t>({value}LL)"
        return f"static_cast<uint64_t>({value}ULL)"
    if isinstance(value, float):
        return _number_text(value)
    return f"std::string({cpp_string(value)})"


def _literal_value_expression(value: Any) -> str:
    """A base::Value expression for a literal."""

    _check_literal(value, where="literal")
    if value is None:
        return "base::Value()"
    if isinstance(value, bool):
        return f"base::Value({'true' if value else 'false'})"
    if isinstance(value, int):
        if -(2**31) <= value < 2**31:
            return f"base::Value({value})"
        return f"base::Value({_number_text(value)})"
    if isinstance(value, float):
        return f"base::Value({_number_text(value)})"
    return f"base::Value({cpp_string(value)})"


def _literal_mismatch(variable: str, value: Any) -> str:
    """A C++ condition that is true when ``*variable`` is not the literal."""

    _check_literal(value, where="literal")
    if value is None:
        return f"!{variable}->is_none()"
    if isinstance(value, bool):
        flag = f"{variable}->GetBool()"
        return f"!({variable}->is_bool() && {flag if value else '!' + flag})"
    if isinstance(value, (int, float)):
        # GetDouble() also reads an int Value.
        return (
            f"!(({variable}->is_int() || {variable}->is_double()) && "
            f"{variable}->GetDouble() == {_number_text(value)})"
        )
    return f"!({variable}->is_string() && {variable}->GetString() == {cpp_string(value)})"


def _child_expressions(expression: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    kind = expression["kind"]
    if kind == "object":
        return [field["type"] for field in expression["fields"].values()]
    if kind == "tagged_union":
        return list(expression["variants"].values())
    if kind == "untagged_union":
        return list(expression["variants"])
    if kind == "array":
        return [expression["items"]]
    if kind == "map":
        return [expression["values"]]
    if kind == "alias":
        return [expression["target"]]
    return []


# ---------------------------------------------------------------------------
# Entry points


def emit(
    ir: SdkIR,
    allowlist: Allowlist,
    *,
    include_path: str = DEFAULT_INCLUDE_PATH,
) -> dict[str, bytes]:
    """Render both files twice and fail when the two renders differ."""

    renders = [
        CppValueEmitter(ir, allowlist, include_path=include_path).render()
        for _ in range(2)
    ]
    if renders[0] != renders[1]:
        raise NondeterministicGenerationError(
            "--cpp-value output differs between two renders"
        )
    return {name: renders[0][name].encode("utf-8") for name in OUTPUT_NAMES}


def write_outputs(out_dir: str | Path, files: Mapping[str, bytes]) -> list[str]:
    """Write changed files atomically; return the names that changed."""

    directory = Path(out_dir)
    directory.mkdir(parents=True, exist_ok=True)
    changed: list[str] = []
    for name in OUTPUT_NAMES:
        destination = directory / name
        content = files[name]
        if destination.is_file() and destination.read_bytes() == content:
            continue
        handle, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=directory)
        try:
            with os.fdopen(handle, "wb") as stream:
                stream.write(content)
            os.replace(temporary, destination)
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise
        changed.append(name)
    return changed


def drifted_outputs(out_dir: str | Path, files: Mapping[str, bytes]) -> list[str]:
    """Return the names whose committed content differs from ``files``."""

    directory = Path(out_dir)
    return [
        name
        for name in OUTPUT_NAMES
        if not (directory / name).is_file()
        or (directory / name).read_bytes() != files[name]
    ]


def run(
    *,
    ir: SdkIR,
    allowlist_path: str | Path,
    out_dir: str | Path,
    mode: str = "write",
    include_path: str = DEFAULT_INCLUDE_PATH,
) -> list[str]:
    """Generate for ``generate.py --cpp-value``.

    In ``write`` mode, return the changed file names. In ``check`` mode, raise
    ``GenerationError`` when a file differs.
    """

    if mode not in {"write", "check"}:
        raise ValueError(f"unknown generation mode {mode!r}")
    files = emit(ir, load_allowlist(allowlist_path), include_path=include_path)
    if mode == "write":
        return write_outputs(out_dir, files)
    drift = drifted_outputs(out_dir, files)
    if drift:
        raise GenerationError(
            f"--cpp-value output in {out_dir} is stale: {', '.join(drift)}"
        )
    return []


__all__: Sequence[str] = (
    "ALLOWLIST_SCHEMA",
    "Allowlist",
    "CppValueEmitter",
    "DEFAULT_INCLUDE_PATH",
    "HEADER_NAME",
    "OUTPUT_NAMES",
    "SOURCE_NAME",
    "drifted_outputs",
    "emit",
    "load_allowlist",
    "parse_allowlist",
    "run",
    "write_outputs",
)
