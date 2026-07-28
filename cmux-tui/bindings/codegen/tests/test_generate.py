from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

from codegen.generate import run_generation, selected_languages
from codegen.writer import (
    Emitter,
    GeneratedOutputDrift,
    GenerationError,
    NondeterministicGenerationError,
)

from support import write_schema


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


if __name__ == "__main__":
    unittest.main()
