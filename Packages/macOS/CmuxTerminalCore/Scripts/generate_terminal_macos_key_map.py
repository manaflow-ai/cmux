#!/usr/bin/env python3
"""Generate Ghostty-free Swift key values from Ghostty's canonical Zig tables."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
KEY_SOURCE = REPO_ROOT / "ghostty" / "src" / "input" / "key.zig"
KEYCODES_SOURCE = REPO_ROOT / "ghostty" / "src" / "input" / "keycodes.zig"
OUTPUT_DIRECTORY = (
    REPO_ROOT
    / "Packages"
    / "macOS"
    / "CmuxTerminalCore"
    / "Sources"
    / "CmuxTerminalDomain"
    / "Input"
)
KEY_OUTPUT = OUTPUT_DIRECTORY / "TerminalW3CKey.generated.swift"
MAP_OUTPUT = OUTPUT_DIRECTORY / "TerminalMacOSKeyMap.generated.swift"


@dataclass(frozen=True)
class CanonicalKey:
    zig_name: str
    swift_name: str
    w3c_name: str
    raw_value: int


@dataclass(frozen=True)
class GeneratedFile:
    path: Path
    contents: str


class GhosttyKeyMapGenerator:
    key_case_pattern = re.compile(r'(?:@"([^"]+)"|([a-z0-9_]+)),')
    code_map_pattern = re.compile(
        r'^\s*\.\{\s*"([^"]+)",\s*\.([a-z0-9_]+)\s*\},\s*$'
    )
    raw_entry_pattern = re.compile(
        r'^\s*\.\{\s*'
        r'(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*'
        r'(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*'
        r'(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*'
        r'(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*'
        r'(0x[0-9a-fA-F]+|[0-9]+)\s*,\s*'
        r'"([^"]*)"\s*\},'
    )

    def __init__(self, key_source: str, keycodes_source: str) -> None:
        self.key_source = key_source
        self.keycodes_source = keycodes_source

    def generate(self) -> list[GeneratedFile]:
        keys = self.parse_keys()
        code_to_key = self.parse_code_to_key()
        macos_map = self.parse_macos_map(keys, code_to_key)
        key_hash = hashlib.sha256(self.key_source.encode()).hexdigest()
        keycodes_hash = hashlib.sha256(self.keycodes_source.encode()).hexdigest()

        return [
            GeneratedFile(
                KEY_OUTPUT,
                self.render_key_enum(keys, key_hash, keycodes_hash),
            ),
            GeneratedFile(
                MAP_OUTPUT,
                self.render_macos_map(macos_map, key_hash, keycodes_hash),
            ),
        ]

    def parse_keys(self) -> list[CanonicalKey]:
        marker = "pub const Key = enum(c_int) {"
        try:
            body = self.key_source.split(marker, 1)[1].split(
                "    pub fn fromASCII", 1
            )[0]
        except IndexError as error:
            raise ValueError("Ghostty Key enum shape changed") from error

        keys: list[CanonicalKey] = []
        for line in body.splitlines():
            candidate = line.split("//", 1)[0].strip()
            match = self.key_case_pattern.fullmatch(candidate)
            if match is None:
                continue
            zig_name = match.group(1) or match.group(2)
            keys.append(
                CanonicalKey(
                    zig_name=zig_name,
                    swift_name=self.swift_case_name(zig_name),
                    w3c_name=self.w3c_name(zig_name),
                    raw_value=len(keys),
                )
            )

        if not keys or keys[0].zig_name != "unidentified":
            raise ValueError("Ghostty Key enum no longer begins with unidentified")
        if len({key.zig_name for key in keys}) != len(keys):
            raise ValueError("Ghostty Key enum contains duplicate names")
        if len({key.swift_name for key in keys}) != len(keys):
            raise ValueError("Swift key case conversion produced duplicate names")
        return keys

    def parse_code_to_key(self) -> dict[str, str]:
        try:
            body = self.keycodes_source.split(
                "const code_to_key = code_to_key:", 1
            )[1].split("});", 1)[0]
        except IndexError as error:
            raise ValueError("Ghostty code_to_key table shape changed") from error

        result: dict[str, str] = {}
        for line in body.splitlines():
            match = self.code_map_pattern.match(line)
            if match is not None:
                result[match.group(1)] = match.group(2)
        if not result:
            raise ValueError("Ghostty code_to_key table is empty")
        return result

    def parse_macos_map(
        self,
        keys: list[CanonicalKey],
        code_to_key: dict[str, str],
    ) -> list[CanonicalKey]:
        if "[_]Key{.unidentified} ** 128" not in self.keycodes_source:
            raise ValueError("Ghostty macOS key table is no longer fixed at 128 entries")

        keys_by_zig_name = {key.zig_name: key for key in keys}
        unidentified = keys_by_zig_name["unidentified"]
        result = [unidentified] * 128
        raw_entry_count = 0

        for line in self.keycodes_source.splitlines():
            match = self.raw_entry_pattern.match(line)
            if match is None:
                continue
            raw_entry_count += 1
            macos_keycode = int(match.group(5), 0)
            w3c_code = match.group(6)
            zig_name = code_to_key.get(w3c_code)
            if macos_keycode >= len(result) or zig_name is None:
                continue
            try:
                result[macos_keycode] = keys_by_zig_name[zig_name]
            except KeyError as error:
                raise ValueError(
                    f"Ghostty code_to_key references unknown Key.{zig_name}"
                ) from error

        if raw_entry_count < 100:
            raise ValueError("Ghostty raw keycode table was not parsed completely")
        if result[0].zig_name != "key_a":
            raise ValueError("Ghostty macOS keycode 0 no longer maps to KeyA")
        if result[126].zig_name != "arrow_up":
            raise ValueError("Ghostty macOS keycode 126 no longer maps to ArrowUp")
        return result

    @staticmethod
    def swift_case_name(zig_name: str) -> str:
        words = zig_name.split("_")
        return words[0] + "".join(word.capitalize() for word in words[1:])

    @staticmethod
    def w3c_name(zig_name: str) -> str:
        return "".join(word.capitalize() for word in zig_name.split("_"))

    @staticmethod
    def generated_header(key_hash: str, keycodes_hash: str) -> str:
        return (
            "// Generated by Scripts/generate_terminal_macos_key_map.py.\n"
            "// Do not edit. Regenerate after changing Ghostty's canonical input tables.\n"
            "// The Chromium-derived key table retains its BSD-style license in ghostty/LICENSE.\n"
            f"// key.zig SHA-256: {key_hash}\n"
            f"// keycodes.zig SHA-256: {keycodes_hash}\n\n"
        )

    def render_key_enum(
        self,
        keys: list[CanonicalKey],
        key_hash: str,
        keycodes_hash: str,
    ) -> str:
        lines = [self.generated_header(key_hash, keycodes_hash)]
        lines.extend(
            [
                "/// Stable Ghostty/W3C physical-key values used across the process boundary.\n",
                "///\n",
                "/// Raw values are generated from Ghostty's `input.Key` declaration so the\n",
                "/// Swift frontend can encode physical keys without importing or linking Ghostty.\n",
                "public enum TerminalW3CKey: UInt32, Equatable, Hashable, Sendable {\n",
            ]
        )
        for key in keys:
            lines.append(
                f"    /// The W3C `{key.w3c_name}` physical key.\n"
                f"    case {key.swift_name} = {key.raw_value}\n"
            )
        lines.append("}\n")
        return "".join(lines)

    def render_macos_map(
        self,
        macos_map: list[CanonicalKey],
        key_hash: str,
        keycodes_hash: str,
    ) -> str:
        lines = [self.generated_header(key_hash, keycodes_hash)]
        lines.extend(
            [
                "/// An immutable O(1) translation from `NSEvent.keyCode` to a physical key.\n",
                "///\n",
                "/// The generated table mirrors Ghostty's Chromium-derived 128-entry macOS map.\n",
                "/// Values outside that fixed native-keycode domain are always unidentified.\n",
                "public struct TerminalMacOSKeyMap: Sendable {\n",
                "    private static let keys: [TerminalW3CKey] = [\n",
            ]
        )
        for keycode, key in enumerate(macos_map):
            lines.append(f"        /* 0x{keycode:02X} */ .{key.swift_name},\n")
        lines.extend(
            [
                "    ]\n\n",
                "    /// Creates a translator backed by the generated canonical table.\n",
                "    public init() {}\n\n",
                "    /// Returns the canonical physical key for a macOS virtual keycode.\n",
                "    ///\n",
                "    /// - Parameter keyCode: The `NSEvent.keyCode` value to translate.\n",
                "    /// - Returns: The matching physical key, or ``TerminalW3CKey/unidentified``.\n",
                "    public func key(for keyCode: UInt16) -> TerminalW3CKey {\n",
                "        guard Int(keyCode) < Self.keys.count else { return .unidentified }\n",
                "        return Self.keys[Int(keyCode)]\n",
                "    }\n",
                "}\n",
            ]
        )
        return "".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when a generated Swift file is stale",
    )
    args = parser.parse_args()

    try:
        generator = GhosttyKeyMapGenerator(
            KEY_SOURCE.read_text(),
            KEYCODES_SOURCE.read_text(),
        )
        generated_files = generator.generate()
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    stale_paths = [
        generated.path
        for generated in generated_files
        if not generated.path.exists()
        or generated.path.read_text() != generated.contents
    ]
    if args.check:
        if stale_paths:
            for path in stale_paths:
                print(f"stale generated key map: {path.relative_to(REPO_ROOT)}")
            return 1
        print("Ghostty-derived macOS key map is current")
        return 0

    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for generated in generated_files:
        generated.path.write_text(generated.contents)
        print(f"wrote {generated.path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
