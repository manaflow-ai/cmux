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
        argv: list[str] | None = None,
        release_version: str = "1.2.3",
        sidebar_version: str | None = None,
        sidebar_sdk_requirement: str | None = None,
        java_version: str | None = None,
        cpp_version: str | None = None,
        zig_manifest_version: str | None = None,
        zig_example_version: str | None = None,
        zig_manifest_source: str | None = None,
        zig_build_source: str | None = None,
        rust_package_name: str = "cmux-sdk",
    ) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            bindings = Path(temporary_directory)
            self.write_fixture(
                bindings,
                release_version=release_version,
                sidebar_version=sidebar_version or release_version,
                sidebar_sdk_requirement=(
                    sidebar_sdk_requirement or f"={release_version}"
                ),
                java_version=java_version or release_version,
                cpp_version=cpp_version or release_version,
                zig_manifest_version=zig_manifest_version or release_version,
                zig_example_version=zig_example_version or release_version,
                zig_manifest_source=zig_manifest_source,
                zig_build_source=zig_build_source,
                rust_package_name=rust_package_name,
            )
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = check_versions.main(argv or [], bindings=bindings)
            return result, stdout.getvalue(), stderr.getvalue()

    def write_fixture(
        self,
        bindings: Path,
        *,
        release_version: str,
        sidebar_version: str,
        sidebar_sdk_requirement: str,
        java_version: str,
        cpp_version: str,
        zig_manifest_version: str,
        zig_example_version: str,
        zig_manifest_source: str | None,
        zig_build_source: str | None,
        rust_package_name: str,
    ) -> None:
        files = {
            "typescript/package.json": f'{{"version": "{release_version}"}}',
            "python/pyproject.toml": (
                f'[project]\nname = "cmux-sdk"\nversion = "{release_version}"\n'
            ),
            "rust/Cargo.toml": (
                f'[package]\nname = "{rust_package_name}"\n'
                f'version = "{release_version}"\n'
            ),
            "rust-sidebar/Cargo.toml": (
                "[package]\n"
                'name = "cmux-sidebar"\n'
                f'version = "{sidebar_version}"\n\n'
                "[dependencies]\n"
                "cmux-sdk = { "
                f'path = "../rust", version = "{sidebar_sdk_requirement}"'
                " }\n"
            ),
            "java/pom.xml": (
                '<project xmlns="http://maven.apache.org/POM/4.0.0">'
                f"<version>{java_version}</version>"
                "</project>"
            ),
            "cpp/CMakeLists.txt": (
                "project(cmux_tui_sdk VERSION "
                f"{cpp_version} LANGUAGES CXX)\n"
            ),
            "zig/build.zig.zon": zig_manifest_source
            if zig_manifest_source is not None
            else (
                ".{\n"
                "    .name = .cmux_tui,\n"
                f'    .version = "{zig_manifest_version}",\n'
                '    .minimum_zig_version = "0.15.2",\n'
                "}\n"
            ),
            "zig/build.zig": zig_build_source
            if zig_build_source is not None
            else (
                "const example = b.addExecutable(.{\n"
                '    .name = "cmux-tui-watch",\n'
                "    .version = std.SemanticVersion.parse(\""
                f'{zig_example_version}") catch unreachable,\n'
                "});\n"
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

    def test_rejects_nonexact_sidebar_sdk_dependency_version(self) -> None:
        result, stdout, stderr = self.run_guard(sidebar_sdk_requirement="1.2.3")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: rust-sidebar cmux-sdk dependency "
            "must be pinned to =1.2.3, found 1.2.3\n",
        )

    def test_rejects_an_unexpected_rust_registry_name(self) -> None:
        result, stdout, stderr = self.run_guard(rust_package_name="cmux-client")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: rust/Cargo.toml package name must be cmux-sdk\n",
        )

    def test_published_only_ignores_unpublished_package_versions(self) -> None:
        result, stdout, stderr = self.run_guard(
            argv=["--published-only"],
            java_version="9.0.0",
            cpp_version="8.0.0",
            zig_manifest_version="7.0.0",
            zig_example_version="7.0.0",
        )

        self.assertEqual(result, 0)
        self.assertIn("Published SDK versions ok: 1.2.3", stdout)
        self.assertIn("typescript", stdout)
        self.assertIn("python", stdout)
        self.assertIn("rust-sidebar", stdout)
        self.assertNotIn("java", stdout)
        self.assertNotIn("cpp", stdout)
        self.assertNotIn("zig", stdout)
        self.assertEqual(stderr, "")

    def test_uses_zig_manifest_as_authoritative_package_version(self) -> None:
        result, stdout, stderr = self.run_guard(zig_manifest_version="1.2.4")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertIn("zig: 1.2.4", stderr)
        self.assertIn("SDK version error: package versions differ", stderr)

    def test_rejects_drift_in_zig_example_executable_version(self) -> None:
        result, stdout, stderr = self.run_guard(zig_example_version="1.2.4")

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig example executable version "
            "must be 1.2.3, found 1.2.4\n",
        )

    def test_rejects_missing_zig_manifest_version(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_manifest_source=".{\n    .name = .cmux_tui,\n}\n"
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig.zon has no package version\n",
        )

    def test_rejects_duplicate_zig_manifest_versions(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_manifest_source=(
                ".{\n"
                '    .version = "1.2.3",\n'
                '    .version = "1.2.4",\n'
                "}\n"
            )
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig.zon has duplicate package versions\n",
        )

    def test_rejects_malformed_zig_manifest_version(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_manifest_source=".{\n    .version = 1.2.3,\n}\n"
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig.zon has a malformed package version\n",
        )

    def test_rejects_zig_incompatible_numeric_versions(self) -> None:
        invalid_versions = (
            "01.2.3",
            "1.02.3",
            "1.2.03",
            f"{check_versions.ZIG_USIZE_MAX + 1}.2.3",
        )
        for version in invalid_versions:
            with self.subTest(source="manifest", version=version):
                result, stdout, stderr = self.run_guard(
                    zig_manifest_version=version
                )
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(
                    stderr,
                    "SDK version error: zig/build.zig.zon has a malformed "
                    "package version\n",
                )
            with self.subTest(source="build", version=version):
                result, stdout, stderr = self.run_guard(zig_example_version=version)
                self.assertEqual(result, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(
                    stderr,
                    "SDK version error: zig/build.zig has a malformed example "
                    "executable version\n",
                )

    def test_accepts_zig_usize_boundary(self) -> None:
        version = f"{check_versions.ZIG_USIZE_MAX}.2.3"
        result, stdout, stderr = self.run_guard(release_version=version)

        self.assertEqual(result, 0)
        self.assertIn(f"SDK versions ok: {version}", stdout)
        self.assertEqual(stderr, "")

    def test_ignores_commented_zig_manifest_versions(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_manifest_source=(
                ".{\n"
                '    // .version = "9.9.9",\n'
                '    .version = "1.2.3", // authoritative package version\n'
                '    .paths = .{ "src", "https://example.test//asset" },\n'
                "}\n"
            )
        )

        self.assertEqual(result, 0)
        self.assertIn("SDK versions ok: 1.2.3", stdout)
        self.assertEqual(stderr, "")

    def test_rejects_missing_zig_example_version(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_build_source='const name = "cmux-tui-watch";\n'
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig has no example executable version\n",
        )

    def test_rejects_duplicate_zig_example_versions(self) -> None:
        declaration = (
            '.version = std.SemanticVersion.parse("1.2.3") catch unreachable,\n'
        )
        result, stdout, stderr = self.run_guard(
            zig_build_source=declaration + declaration
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig has duplicate example executable "
            "versions\n",
        )

    def test_rejects_malformed_zig_example_version(self) -> None:
        result, stdout, stderr = self.run_guard(
            zig_build_source=".version = 1.2.3,\n"
        )

        self.assertEqual(result, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "SDK version error: zig/build.zig has a malformed example executable "
            "version\n",
        )


if __name__ == "__main__":
    unittest.main()
