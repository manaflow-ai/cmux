"""Read the serde wire types of a Rust crate's source: structs and enums, their fields, docs and serde attributes.

The reader covers the shapes the app FFI's rule crates use (cmux-window-rules): named-field structs, unit, struct
and newtype enum variants, `rename_all`, `rename`, `default`, `tag`, `other`, `skip_serializing_if` and `flatten`.
It never guesses: an attribute or a shape it does not know is kept as is, and the emitter refuses a type that uses
one, so a Rust change the generator cannot express fails `generate.py --check` and the build instead of producing a
Swift type with a different wire.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


class RustReadError(ValueError):
    pass


@dataclass(slots=True)
class Attrs:
    derives: set[str] = field(default_factory=set)
    serde: dict[str, str | bool] = field(default_factory=dict)
    docs: list[str] = field(default_factory=list)
    cfg_test: bool = False


@dataclass(slots=True)
class Field:
    name: str  # the Rust name; the tuple position for a newtype variant ("0")
    type: str  # the Rust type, whitespace-normalized
    attrs: Attrs


@dataclass(slots=True)
class Variant:
    name: str
    kind: str  # "unit", "struct" or "tuple"
    fields: list[Field]
    attrs: Attrs


@dataclass(slots=True)
class Item:
    kind: str  # "struct" or "enum"
    name: str
    module: str  # `close`, `chat::host_op_pane`
    path: Path
    attrs: Attrs
    fields: list[Field] = field(default_factory=list)  # a struct's
    variants: list[Variant] = field(default_factory=list)  # an enum's
    tuple: bool = False  # a tuple or unit struct


_LINE_COMMENT = re.compile(r"(?<!:)//(?!/)[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_ITEM = re.compile(r"\b(?:pub(?:\([^)]*\))?\s+)?(struct|enum)\s+([A-Z]\w*)\s*(<[^{;(]*>)?\s*")


def _strip_comments(text: str) -> str:
    """Drop `//` and `/* */` comments, keep `///` docs. A `//` inside a string literal (a URL) is kept."""
    out: list[str] = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("///") or stripped.startswith("//!"):
            out.append(line if stripped.startswith("///") else "")
            continue
        out.append(_strip_line_comment(line))
    return _BLOCK_COMMENT.sub("", "\n".join(out))


def _strip_line_comment(line: str) -> str:
    in_string = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and in_string:
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def _match_close(text: str, start: int, open_char: str, close_char: str) -> int:
    """The index of the bracket closing the one at `start`, skipping string and char literals."""
    depth = 0
    index = start
    in_string = False
    while index < len(text):
        char = text[index]
        if not in_string and text.startswith("///", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
            continue
        if in_string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == open_char:
            depth += 1
        elif char == close_char:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise RustReadError(f"unbalanced {open_char!r} at {start}")


def _split_top(text: str, separator: str = ",") -> list[str]:
    """Split at `separator` outside (), [], {} and <>."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    in_string = False
    previous = ""
    index = 0
    while index < len(text):
        char = text[index]
        index += 1
        if not in_string and char == "/" and text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            current.append(text[index - 1 : end])
            index = end
            previous = ""
            continue
        if in_string:
            current.append(char)
            if char == '"' and previous != "\\":
                in_string = False
            previous = char
            continue
        if char == '"':
            in_string = True
        elif char in "([{<":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == ">" and previous != "-":
            depth -= 1
        if char == separator and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        previous = char
    if "".join(current).strip():
        parts.append("".join(current))
    return parts


def _parse_serde(body: str, into: dict[str, str | bool]) -> None:
    for part in _split_top(body):
        part = part.strip()
        if not part:
            continue
        if "=" in part and not part.startswith(("with(", "bound(")):
            key, _, value = part.partition("=")
            value = value.strip()
            into[key.strip()] = value[1:-1] if value.startswith('"') and value.endswith('"') else value
        else:
            into[part] = True


def _read_attrs(prefix: str) -> Attrs:
    """The docs and attributes in `prefix` (the text between the previous item and this one)."""
    attrs = Attrs()
    index = 0
    while index < len(prefix):
        rest = prefix[index:]
        stripped = rest.lstrip()
        index += len(rest) - len(stripped)
        if not stripped:
            break
        if stripped.startswith("///"):
            end = stripped.find("\n")
            line = stripped[3:] if end < 0 else stripped[3:end]
            attrs.docs.append(line[1:] if line.startswith(" ") else line)
            index += len(stripped) if end < 0 else end + 1
            continue
        if stripped.startswith("#["):
            close = _match_close(prefix, index + 1, "[", "]")
            body = prefix[index + 2 : close].strip()
            index = close + 1
            if body.startswith("derive("):
                attrs.derives.update(name.strip().split("::")[-1] for name in body[7:-1].split(",") if name.strip())
            elif body.startswith("serde("):
                _parse_serde(body[6:-1], attrs.serde)
            elif body.startswith("cfg(test") or body == "cfg(test)":
                attrs.cfg_test = True
            elif body.startswith("cfg_attr("):
                inner = body[len("cfg_attr(") : -1]
                derive = re.search(r"derive\(([^)]*)\)", inner)
                if derive:
                    attrs.derives.update(name.strip().split("::")[-1] for name in derive.group(1).split(",") if name.strip())
            continue
        break
    return attrs


def _normalize_type(text: str) -> str:
    return re.sub(r"\s+", " ", text).replace("< ", "<").replace(" >", ">").replace(" ,", ",").strip()


def _read_fields(body: str) -> list[Field]:
    fields: list[Field] = []
    for part in _split_top(body):
        if not part.strip():
            continue
        attrs, rest = _attrs_and_rest(part)
        match = re.match(r"\s*(?:pub(?:\([^)]*\))?\s+)?(r#)?(\w+)\s*:\s*(.+)$", rest, re.S)
        if not match:
            raise RustReadError(f"cannot read field {part.strip()!r}")
        fields.append(Field(match.group(2), _normalize_type(match.group(3)), attrs))
    return fields


def _attrs_and_rest(part: str) -> tuple[Attrs, str]:
    """Split a field or variant into its leading docs and attributes and the declaration after them."""
    index = 0
    while True:
        rest = part[index:]
        stripped = rest.lstrip()
        index += len(rest) - len(stripped)
        if stripped.startswith("///"):
            end = stripped.find("\n")
            index += len(stripped) if end < 0 else end + 1
        elif stripped.startswith("#["):
            index = _match_close(part, index + 1, "[", "]") + 1
        else:
            break
    return _read_attrs(part[:index]), part[index:]


def _read_variants(body: str) -> list[Variant]:
    variants: list[Variant] = []
    for part in _split_top(body):
        if not part.strip():
            continue
        attrs, rest = _attrs_and_rest(part)
        rest = rest.strip()
        match = re.match(r"(\w+)\s*(.*)$", rest, re.S)
        if not match:
            raise RustReadError(f"cannot read variant {part.strip()!r}")
        name, tail = match.group(1), match.group(2).strip()
        if not tail or tail.startswith("="):
            variants.append(Variant(name, "unit", [], attrs))
        elif tail.startswith("{"):
            variants.append(Variant(name, "struct", _read_fields(tail[1:-1]), attrs))
        elif tail.startswith("("):
            types = [_normalize_type(t) for t in _split_top(tail[1:-1]) if t.strip()]
            variants.append(Variant(name, "tuple", [Field(str(i), t, Attrs()) for i, t in enumerate(types)], attrs))
        else:
            raise RustReadError(f"cannot read variant {rest!r}")
    return variants


def module_of(path: Path, src: Path) -> str:
    relative = path.relative_to(src).with_suffix("")
    parts = list(relative.parts)
    if parts and parts[-1] in {"mod", "lib"}:
        parts.pop()
    return "::".join(parts)


def read_file(path: Path, src: Path) -> list[Item]:
    text = _strip_comments(path.read_text(encoding="utf-8"))
    module = module_of(path, src)
    items: list[Item] = []
    position = 0
    last_end = 0
    test_mod = re.search(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{", text)
    test_start = test_mod.start() if test_mod else len(text)
    while True:
        match = _ITEM.search(text, position)
        if not match or match.start() >= test_start:
            break
        prefix_start = max(last_end, text.rfind("}", 0, match.start()) + 1, text.rfind(";", 0, match.start()) + 1)
        attrs = _read_attrs(text[prefix_start : match.start()])
        kind, name = match.group(1), match.group(2)
        after = match.end()
        opener = text[after : after + 1]
        if text.startswith("where", after):
            opener = "{"
            after = text.index("{", after)
        if opener == "{":
            close = _match_close(text, after, "{", "}")
            body = text[after + 1 : close]
            item = Item(kind, name, module, path, attrs)
            if kind == "struct":
                item.fields = _read_fields(body)
            else:
                item.variants = _read_variants(body)
            position = last_end = close + 1
        elif opener == "(":
            close = _match_close(text, after, "(", ")")
            item = Item(kind, name, module, path, attrs, tuple=True)
            item.fields = [Field(str(i), _normalize_type(t), Attrs()) for i, t in enumerate(_split_top(text[after + 1 : close])) if t.strip()]
            position = last_end = close + 1
        else:
            item = Item(kind, name, module, path, attrs, tuple=True)
            position = last_end = after + 1
        if not attrs.cfg_test:
            items.append(item)
    return items


def read_crate(src: Path) -> dict[str, Item]:
    """Every struct and enum of the crate under `src` by `module::Name`, its tests (`*_tests.rs`, `tests/`) left out."""
    items: dict[str, Item] = {}
    for path in sorted(src.rglob("*.rs")):
        if path.name.endswith("_tests.rs") or "tests" in path.relative_to(src).parts[:-1] or path.name == "tests.rs":
            continue
        for item in read_file(path, src):
            key = f"{item.module}::{item.name}" if item.module else item.name
            items.setdefault(key, item)
    return items
