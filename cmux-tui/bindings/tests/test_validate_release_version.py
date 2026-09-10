from __future__ import annotations

import contextlib
import importlib.util
import io
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "validate_release_version.py"
SPEC = importlib.util.spec_from_file_location("validate_release_version", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
validate_release_version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validate_release_version)


class ValidateReleaseVersionTests(unittest.TestCase):
    def test_accepts_v0_and_v1(self) -> None:
        for version in ("0.1.0", "1.0.0", "1.42.7"):
            with self.subTest(version=version):
                validate_release_version.validate_release_version(version)

    def test_rejects_v2_until_the_go_module_path_changes(self) -> None:
        with self.assertRaisesRegex(ValueError, "Go module path"):
            validate_release_version.validate_release_version("2.0.0")

    def test_rejects_non_semantic_versions(self) -> None:
        for version in ("1.0", "01.0.0", "1.0.0-rc.1", "v1.0.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_release_version.validate_release_version(version)

    def test_requires_a_strict_numeric_increase(self) -> None:
        tags = ["cmux-sdk-v1.2.9", "cmux-sdk-v1.10.0"]
        latest = validate_release_version.validate_release_version(
            "1.10.1", tags, require_newer=True
        )
        self.assertEqual(latest, (1, 10, 0))

        for version in ("1.10.0", "1.9.99"):
            with self.subTest(version=version), self.assertRaisesRegex(
                ValueError, "must be greater"
            ):
                validate_release_version.validate_release_version(
                    version, tags, require_newer=True
                )

    def test_ignores_unrelated_and_malformed_tags(self) -> None:
        latest = validate_release_version.validate_release_version(
            "1.0.0",
            ["cmux-tui-v99.0.0", "cmux-sdk-vgarbage"],
            require_newer=True,
        )
        self.assertIsNone(latest)

    def test_publish_requires_the_latest_release_tag(self) -> None:
        tags = ["cmux-sdk-v1.1.0", "cmux-sdk-v1.2.0"]
        latest = validate_release_version.validate_release_version(
            "1.2.0", tags, require_latest=True
        )
        self.assertEqual(latest, (1, 2, 0))

        with self.assertRaisesRegex(ValueError, "older than latest"):
            validate_release_version.validate_release_version(
                "1.1.0", tags, require_latest=True
            )

    def test_cli_reads_existing_tags_from_stdin(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        stdin = io.StringIO("cmux-sdk-v1.0.0\n")
        with (
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
            mock.patch("sys.stdin", stdin),
        ):
            result = validate_release_version.main(
                ["--version", "1.0.0", "--require-newer-than-tags"]
            )
        self.assertEqual(result, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("must be greater", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
