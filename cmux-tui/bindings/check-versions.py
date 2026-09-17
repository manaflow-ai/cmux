#!/usr/bin/env python3
"""Require every versioned cmux-tui SDK package to use one release version."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path


BINDINGS = Path(__file__).resolve().parent
SEMANTIC_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
)
ZIG_USIZE_MAX = sys.maxsize * 2 + 1
ZIG_USIZE_MAX_TEXT = str(ZIG_USIZE_MAX)


def _is_zig_semantic_version(version: str) -> bool:
    match = SEMANTIC_VERSION.fullmatch(version)
    if match is None:
        return False
    return all(
        len(component) < len(ZIG_USIZE_MAX_TEXT)
        or (
            len(component) == len(ZIG_USIZE_MAX_TEXT)
            and component <= ZIG_USIZE_MAX_TEXT
        )
        for component in match.groups()
    )


def _strip_zig_line_comments(source: str) -> str:
    """Strip // comments without treating comment markers in strings as syntax."""

    output: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(source):
        character = source[index]
        if in_string:
            output.append(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
            output.append(character)
            index += 1
            continue
        if source.startswith("//", index):
            while index < len(source) and source[index] not in "\r\n":
                output.append(" ")
                index += 1
            continue
        output.append(character)
        index += 1
    if in_string:
        raise ValueError("zig/build.zig.zon has an unterminated string")
    return "".join(output)


def _zig_zon_root_fields(source: str) -> list[str]:
    """Split the fixed build.zig.zon root struct into top-level fields."""

    source = _strip_zig_line_comments(source)
    start = 0
    while start < len(source) and source[start].isspace():
        start += 1
    if not source.startswith(".{", start):
        raise ValueError("zig/build.zig.zon must contain a root struct")

    fields: list[str] = []
    field_start = start + 2
    curly_depth = 1
    square_depth = 0
    paren_depth = 0
    in_string = False
    escaped = False
    index = field_start
    while index < len(source):
        character = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            curly_depth += 1
        elif character == "}":
            if curly_depth == 1:
                if square_depth != 0 or paren_depth != 0:
                    raise ValueError("zig/build.zig.zon has unbalanced delimiters")
                final_field = source[field_start:index].strip()
                if final_field:
                    fields.append(final_field)
                remainder = source[index + 1 :]
                if remainder.strip():
                    raise ValueError(
                        "zig/build.zig.zon has content after its root struct"
                    )
                return fields
            curly_depth -= 1
        elif character == "[":
            square_depth += 1
        elif character == "]":
            square_depth -= 1
            if square_depth < 0:
                raise ValueError("zig/build.zig.zon has unbalanced delimiters")
        elif character == "(":
            paren_depth += 1
        elif character == ")":
            paren_depth -= 1
            if paren_depth < 0:
                raise ValueError("zig/build.zig.zon has unbalanced delimiters")
        elif (
            character == ","
            and curly_depth == 1
            and square_depth == 0
            and paren_depth == 0
        ):
            field = source[field_start:index].strip()
            if field:
                fields.append(field)
            field_start = index + 1
        index += 1

    raise ValueError("zig/build.zig.zon has an unterminated root struct")


def read_zig_package_version(bindings: Path = BINDINGS) -> str:
    source = (bindings / "zig/build.zig.zon").read_text(encoding="utf-8")
    declarations: list[str] = []
    for field in _zig_zon_root_fields(source):
        match = re.fullmatch(
            r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)", field, re.DOTALL
        )
        if match is not None and match.group(1) == "version":
            declarations.append(match.group(2).strip())
    if not declarations:
        raise ValueError("zig/build.zig.zon has no package version")
    if len(declarations) != 1:
        raise ValueError("zig/build.zig.zon has duplicate package versions")
    match = re.fullmatch(r'"([^"]*)"', declarations[0])
    if match is None or not _is_zig_semantic_version(match.group(1)):
        raise ValueError("zig/build.zig.zon has a malformed package version")
    return match.group(1)


def read_zig_example_version(bindings: Path = BINDINGS) -> str:
    source = (bindings / "zig/build.zig").read_text(encoding="utf-8")
    declarations = re.findall(
        r"(?m)^\s*\.version\s*=\s*(.+?),\s*(?://[^\r\n]*)?$", source
    )
    if not declarations:
        raise ValueError("zig/build.zig has no example executable version")
    if len(declarations) != 1:
        raise ValueError("zig/build.zig has duplicate example executable versions")
    match = re.fullmatch(
        r'std\.SemanticVersion\.parse\(\s*"([^"]*)"\s*\)\s*catch\s+unreachable',
        declarations[0].strip(),
    )
    if match is None or not _is_zig_semantic_version(match.group(1)):
        raise ValueError("zig/build.zig has a malformed example executable version")
    return match.group(1)


def read_versions(bindings: Path = BINDINGS) -> dict[str, str]:
    typescript = json.loads(
        (bindings / "typescript/package.json").read_text(encoding="utf-8")
    )["version"]
    python = tomllib.loads(
        (bindings / "python/pyproject.toml").read_text(encoding="utf-8")
    )["project"]["version"]
    rust = tomllib.loads(
        (bindings / "rust/Cargo.toml").read_text(encoding="utf-8")
    )["package"]["version"]
    rust_sidebar_manifest = tomllib.loads(
        (bindings / "rust-sidebar/Cargo.toml").read_text(encoding="utf-8")
    )
    rust_sidebar = rust_sidebar_manifest["package"]["version"]

    java_root = ET.parse(bindings / "java/pom.xml").getroot()
    java = java_root.findtext("{http://maven.apache.org/POM/4.0.0}version")
    if java is None:
        raise ValueError("java/pom.xml has no project version")

    cpp_source = (bindings / "cpp/CMakeLists.txt").read_text(encoding="utf-8")
    cpp_match = re.search(
        r"(?m)^project\(cmux_tui_sdk VERSION ([0-9]+\.[0-9]+\.[0-9]+) ",
        cpp_source,
    )
    if cpp_match is None:
        raise ValueError("cpp/CMakeLists.txt has no cmux_tui_sdk project version")

    zig = read_zig_package_version(bindings)

    return {
        "typescript": str(typescript),
        "python": str(python),
        "rust": str(rust),
        "rust-sidebar": str(rust_sidebar),
        "java": java,
        "cpp": cpp_match.group(1),
        "zig": zig,
    }


def read_sidebar_client_version(bindings: Path = BINDINGS) -> str:
    manifest = tomllib.loads(
        (bindings / "rust-sidebar/Cargo.toml").read_text(encoding="utf-8")
    )
    dependency = manifest.get("dependencies", {}).get("cmux-client")
    if not isinstance(dependency, dict) or "version" not in dependency:
        raise ValueError(
            "rust-sidebar/Cargo.toml cmux-client dependency has no version"
        )
    version = dependency["version"]
    if not isinstance(version, str):
        raise ValueError(
            "rust-sidebar/Cargo.toml cmux-client dependency version is not a string"
        )
    return version


def main(argv: list[str] | None = None, *, bindings: Path = BINDINGS) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", help="require this X.Y.Z release version")
    arguments = parser.parse_args(argv)
    try:
        versions = read_versions(bindings)
        sidebar_client_version = read_sidebar_client_version(bindings)
        zig_example_version = read_zig_example_version(bindings)
    except (OSError, KeyError, ValueError, ET.ParseError) as error:
        print(f"SDK version error: {error}", file=sys.stderr)
        return 1

    distinct = set(versions.values())
    if len(distinct) != 1:
        for language, version in sorted(versions.items()):
            print(f"{language}: {version}", file=sys.stderr)
        print("SDK version error: package versions differ", file=sys.stderr)
        return 1
    version = distinct.pop()
    if sidebar_client_version != version:
        print(
            "SDK version error: rust-sidebar cmux-client dependency "
            f"must be {version}, found {sidebar_client_version}",
            file=sys.stderr,
        )
        return 1
    if zig_example_version != version:
        print(
            "SDK version error: zig/build.zig example executable version "
            f"must be {version}, found {zig_example_version}",
            file=sys.stderr,
        )
        return 1
    if arguments.expected is not None and version != arguments.expected:
        print(
            f"SDK version error: expected {arguments.expected}, found {version}",
            file=sys.stderr,
        )
        return 1
    print(
        f"SDK versions ok: {version} "
        f"({', '.join(sorted(versions))}; Go follows the shared Git tag)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
