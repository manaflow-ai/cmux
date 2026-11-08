from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path, PurePosixPath

from codegen.ir import load_ir_document
from codegen.writer import (
    MANIFEST_FILENAME,
    Emitter,
    GeneratedOutputDrift,
    GenerationError,
    NondeterministicGenerationError,
    check_generated,
    generate_twice,
    write_generated,
)

from support import schema_document


class WriterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.ir = load_ir_document(schema_document())
        self.emitter = Emitter(
            language="test",
            output_root=PurePosixPath("test/generated"),
            render=lambda ir: {
                "z.txt": f"protocol={ir.mux_protocol}\r\n",
                "nested/a.txt": ir.ir_sha256 + "\n",
            },
        )

    def test_generates_sorted_manifest_and_normalizes_line_endings(self) -> None:
        tree = generate_twice(self.emitter, self.ir)
        self.assertEqual(tree.files[PurePosixPath("z.txt")], b"protocol=10\n")
        manifest = json.loads(
            tree.files[PurePosixPath(MANIFEST_FILENAME)].decode("utf-8")
        )
        self.assertEqual(manifest["language"], "test")
        self.assertEqual(
            [item["path"] for item in manifest["files"]],
            ["nested/a.txt", "z.txt"],
        )
        self.assertEqual(manifest["ir_sha256"], self.ir.ir_sha256)

    def test_write_then_check_is_clean(self) -> None:
        tree = generate_twice(self.emitter, self.ir)
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            write_generated(root, tree)
            check_generated(root, tree)

    def test_check_reports_changed_and_missing_files(self) -> None:
        tree = generate_twice(self.emitter, self.ir)
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            write_generated(root, tree)
            output = root / "test" / "generated"
            (output / "z.txt").write_text("changed\n", encoding="utf-8")
            (output / "nested" / "a.txt").unlink()
            with self.assertRaises(GeneratedOutputDrift) as raised:
                check_generated(root, tree)
        self.assertIn("changed z.txt", raised.exception.problems)
        self.assertIn("missing nested/a.txt", raised.exception.problems)

    def test_write_removes_only_manifest_owned_stale_files(self) -> None:
        first = generate_twice(self.emitter, self.ir)
        replacement = Emitter(
            language="test",
            output_root=self.emitter.output_root,
            render=lambda _: {"current.txt": "current\n"},
        )
        second = generate_twice(replacement, self.ir)
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            write_generated(root, first)
            output = root / "test" / "generated"
            (output / "handwritten.txt").write_text("keep\n", encoding="utf-8")
            with self.assertRaisesRegex(GeneratedOutputDrift, "stale owned file"):
                check_generated(root, second)
            write_generated(root, second)
            self.assertFalse((output / "z.txt").exists())
            self.assertFalse((output / "nested" / "a.txt").exists())
            self.assertEqual(
                (output / "handwritten.txt").read_text(encoding="utf-8"), "keep\n"
            )
            check_generated(root, second)

    def test_detects_nondeterministic_emitter(self) -> None:
        calls = 0

        def render(_):
            nonlocal calls
            calls += 1
            return {"value.txt": str(calls)}

        emitter = Emitter(
            language="test",
            output_root=PurePosixPath("test/generated"),
            render=render,
        )
        with self.assertRaises(NondeterministicGenerationError):
            generate_twice(emitter, self.ir)

    def test_rejects_escaping_and_reserved_paths(self) -> None:
        for path in ("../outside", "/absolute", MANIFEST_FILENAME):
            with self.subTest(path=path):
                emitter = Emitter(
                    language="test",
                    output_root=PurePosixPath("test/generated"),
                    render=lambda _, path=path: {path: "bad"},
                )
                with self.assertRaises(GenerationError):
                    generate_twice(emitter, self.ir)


if __name__ == "__main__":
    unittest.main()
