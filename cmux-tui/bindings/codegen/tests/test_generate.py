from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

from codegen.generate import (
    available_languages,
    load_emitter,
    run_generation,
    selected_languages,
)
from codegen.ir import load_ir
from codegen.writer import (
    Emitter,
    GeneratedOutputDrift,
    GenerationError,
    NondeterministicGenerationError,
    generate_twice,
)

from support import write_schema


LIVE_SCHEMA = Path(__file__).resolve().parents[3] / "spec" / "sdk-schema.json"


class GenerateTests(unittest.TestCase):
    def test_direct_cli_lists_emitters_in_sorted_order(self) -> None:
        script = Path(__file__).resolve().parents[1] / "generate.py"
        result = subprocess.run(
            [sys.executable, str(script), "--list-languages"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        languages = result.stdout.splitlines()
        self.assertEqual(languages, sorted(languages))

    def test_selects_all_or_deduplicated_requested_languages(self) -> None:
        self.assertEqual(
            selected_languages([], discovered=["rust", "go"]),
            ("go", "rust"),
        )
        self.assertEqual(
            selected_languages(
                ["rust", "go", "rust"], discovered=["rust", "go", "java"]
            ),
            ("go", "rust"),
        )
        with self.assertRaisesRegex(GenerationError, "unknown SDK language"):
            selected_languages(["zig"], discovered=["rust"])

    def test_write_and_check_selected_emitters(self) -> None:
        emitters = {
            language: Emitter(
                language=language,
                output_root=PurePosixPath(language, "generated"),
                render=lambda ir, language=language: {
                    f"{language}.txt": ir.ir_sha256 + "\n"
                },
            )
            for language in ("go", "rust")
        }
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            schema = write_schema(root)
            completed = run_generation(
                mode="write",
                schema=schema,
                bindings_root=root / "bindings",
                languages=["rust", "go"],
                emitter_loader=emitters.__getitem__,
                discovered_languages=emitters,
            )
            self.assertEqual(completed, ("go", "rust"))
            self.assertEqual(
                run_generation(
                    mode="check",
                    schema=schema,
                    bindings_root=root / "bindings",
                    languages=[],
                    emitter_loader=emitters.__getitem__,
                    discovered_languages=emitters,
                ),
                ("go", "rust"),
            )
            (root / "bindings" / "go" / "generated" / "go.txt").write_text(
                "stale\n", encoding="utf-8"
            )
            with self.assertRaises(GeneratedOutputDrift):
                run_generation(
                    mode="check",
                    schema=schema,
                    bindings_root=root / "bindings",
                    languages=["go"],
                    emitter_loader=emitters.__getitem__,
                    discovered_languages=emitters,
                )

    def test_stages_every_language_before_writing_any(self) -> None:
        calls = 0

        def unstable(_):
            nonlocal calls
            calls += 1
            return {"rust.txt": str(calls)}

        emitters = {
            "go": Emitter(
                language="go",
                output_root=PurePosixPath("go"),
                render=lambda _: {"generated.go": "package cmux\n"},
            ),
            "rust": Emitter(
                language="rust",
                output_root=PurePosixPath("rust/src/generated"),
                render=unstable,
            ),
        }
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            schema = write_schema(root)
            with self.assertRaises(NondeterministicGenerationError):
                run_generation(
                    mode="write",
                    schema=schema,
                    bindings_root=root / "bindings",
                    languages=[],
                    emitter_loader=emitters.__getitem__,
                    discovered_languages=emitters,
                )
            self.assertFalse((root / "bindings" / "go").exists())

    def test_live_v10_raw_commands_and_types_emit_for_all_languages(self) -> None:
        markers = {
            "cpp": (
                "Client::clear_history(",
                "Client::new_pane_right(",
                "Client::set_viewport_pane_width(",
                "Client::undo_layout(",
                "enum class TerminalKey {",
                "struct LayoutUndoResult {",
            ),
            "go": (
                "func (c *Client) ClearHistory(",
                "func (c *Client) NewPaneRight(",
                "func (c *Client) SetViewportPaneWidth(",
                "func (c *Client) UndoLayout(",
                "type TerminalKey string",
                "type LayoutUndoResult struct {",
            ),
            "java": (
                "EmptyResult clearHistory(",
                "SurfaceResult newPaneRight(",
                "EmptyResult setViewportPaneWidth(",
                "LayoutUndoResult undoLayout(",
                "public enum TerminalKey implements WireEnum {",
                "public final class LayoutUndoResult implements WireValue {",
            ),
            "python": (
                "def clear_history(",
                "def new_pane_right(",
                "def set_viewport_pane_width(",
                "def undo_layout(",
                "class TerminalKey(str, Enum):",
                "LayoutUndoResult = Union[",
            ),
            "rust": (
                "pub fn clear_history(",
                "pub fn new_pane_right(",
                "pub fn set_viewport_pane_width(",
                "pub fn undo_layout(",
                "pub enum TerminalKey {",
                "pub enum LayoutUndoResult {",
            ),
            "typescript": (
                "export interface ClearHistoryRequest",
                "export interface NewPaneRightRequest",
                "export interface SetViewportPaneWidthRequest",
                "export interface UndoLayoutRequest",
                "export type TerminalKey =",
                "export type LayoutUndoResult =",
            ),
            "zig": (
                "pub fn clearHistory(",
                "pub fn newPaneRight(",
                "pub fn setViewportPaneWidth(",
                "pub fn undoLayout(",
                "pub const TerminalKey = enum {",
                "pub const LayoutUndoResult = union(enum) {",
            ),
        }
        self.assertEqual(available_languages(), tuple(sorted(markers)))
        ir = load_ir(LIVE_SCHEMA)
        for language, expected_markers in markers.items():
            with self.subTest(language=language):
                tree = generate_twice(load_emitter(language), ir)
                generated = b"\n".join(
                    content
                    for path, content in tree.files.items()
                    if path.name != ".cmux-sdk-manifest.json"
                ).decode("utf-8")
                for marker in expected_markers:
                    self.assertIn(marker, generated)


if __name__ == "__main__":
    unittest.main()
