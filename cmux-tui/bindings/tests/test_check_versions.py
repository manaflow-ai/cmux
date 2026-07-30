from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check-versions.py"
SPEC = importlib.util.spec_from_file_location("check_versions", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
check_versions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_versions)


class CheckVersionsTests(unittest.TestCase):
    def run_guard(
        self,
        *,
        release_version: str = "1.2.3",
        sidebar_version: str | None = None,
        sidebar_client_version: str | None = None,
    ) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            bindings = Path(temporary_directory)
            self.write_fixture(
                bindings,
                release_version=release_version,
                sidebar_version=sidebar_version or release_version,
                sidebar_client_version=sidebar_client_version or release_version,
            )
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = check_versions.main([], bindings=bindings)
            return result, stdout.getvalue(), stderr.getvalue()

    def write_fixture(
        self,
        bindings: Path,
        *,
        release_version: str,
        sidebar_version: str,
        sidebar_client_version: str,
    ) -> None:
        files = {
            "typescript/package.json": f'{{"version": "{release_version}"}}',
            "python/pyproject.toml": (
                f'[project]\nname = "cmux"\nversion = "{release_version}"\n'
            ),
            "rust/Cargo.toml": (
                f'[package]\nname = "cmux-client"\nversion = "{release_version}"\n'
            ),
            "rust-sidebar/Cargo.toml": (
                "[package]\n"
                'name = "cmux-sidebar"\n'
                f'version = "{sidebar_version}"\n\n'
                "[dependencies]\n"
                "cmux-client = { "
                f'path = "../rust", version = "{sidebar_client_version}"'
                " }\n"
            ),
            "java/pom.xml": (
                '<project xmlns="http://maven.apache.org/POM/4.0.0">'
                f"<version>{release_version}</version>"
                "</project>"
            ),
            "cpp/CMakeLists.txt": (
                "project(cmux_tui_sdk VERSION "
                f"{release_version} LANGUAGES CXX)\n"
            ),
            "zig/build.zig": (
                'const version = std.SemanticVersion.parse("'
                f'{release_version}") catch unreachable;\n'
            ),
        }
        for relative_path, contents in files.items():
            path = bindings / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")

    def test_accepts_synchronized_sidebar_versions(self) -> None:
        result, stdout, stderr = self.run_guard()

        self.assertEqual(result, 0)
        self.assertIn("SDK versions ok: 1.2.3", stdout)
        self.assertIn("rust-sidebar", stdout)
        self.assertEqual(stderr, "")

    def test_rejects_mismatched_sidebar_package_version(self) -> None:
        result, stdout, stderr = self.run_guard(sidebar_version="1.2.4")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("rust-sidebar: 1.2.4", stderr)
        self.assertIn("SDK version error: package versions differ", stderr)

    def test_rejects_nonmatching_sidebar_client_dependency_version(self) -> None:
        result, stdout, stderr = self.run_guard(sidebar_client_version="^1.2.3")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: rust-sidebar cmux-client dependency "
            "must be 1.2.3, found ^1.2.3\n",
        )


if __name__ == "__main__":
    unittest.main()
