"""Every published cmux SDK package ships the cmux GPL LICENSE text and no compiled code.

The SDKs (crates cmux-sdk and cmux-sidebar, npm cmux-sdk, PyPI cmux-sdk, the Go
modules) are source only. A package that starts to ship a compiled file needs
third-party notices first, so the check refuses it until those exist.
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


BINDINGS = Path(__file__).resolve().parents[1]
REPO = BINDINGS.parents[1]
SCRIPT = BINDINGS / "check_package_license.py"
SPEC = importlib.util.spec_from_file_location("check_package_license", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check
SPEC.loader.exec_module(check)

GPL = (REPO / "cmux-tui/dist/npm/cmux/LICENSE").read_bytes()
ELF = b"\x7fELF\x02\x01\x01" + b"\0" * 57


def _tar_gz(path: Path, files: dict[str, bytes]) -> Path:
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return path


def _zip(path: Path, files: dict[str, bytes]) -> Path:
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return path


CARGO = b'[package]\nname = "cmux-sdk"\nversion = "1.2.3"\nlicense = "GPL-3.0-or-later"\n'
PACKAGE_JSON = json.dumps({"name": "cmux-sdk", "version": "1.2.3", "license": "GPL-3.0-or-later"}).encode()
METADATA = (
    b"Metadata-Version: 2.4\nName: cmux-sdk\nVersion: 1.2.3\n"
    b"License-Expression: GPL-3.0-or-later\nLicense-File: LICENSE\n"
)
WHEEL = b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"


class RepositoryTests(unittest.TestCase):
    def test_every_published_sdk_directory_ships_the_gpl_text(self) -> None:
        self.assertEqual(check.check_repository(REPO), [])

    def test_every_published_sdk_is_registered(self) -> None:
        names = {package.name for package in check.PACKAGES}
        self.assertTrue(
            {"cmux-sdk (crate)", "cmux-sidebar (crate)", "cmux-sdk (npm)", "cmux-sdk (pypi)", "go", "go-pane"}
            <= names,
            names,
        )


class CrateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def crate(self, files: dict[str, bytes]) -> Path:
        return _tar_gz(self.tmp / "cmux-sdk-1.2.3.crate", files)

    def test_accepts_the_gpl_text_and_license_field(self) -> None:
        path = self.crate({"cmux-sdk-1.2.3/Cargo.toml": CARGO, "cmux-sdk-1.2.3/LICENSE": GPL, "cmux-sdk-1.2.3/src/lib.rs": b""})
        self.assertEqual(check.check_artifact("crate", path), [])

    def test_refuses_a_missing_license(self) -> None:
        path = self.crate({"cmux-sdk-1.2.3/Cargo.toml": CARGO, "cmux-sdk-1.2.3/src/lib.rs": b""})
        self.assertTrue(any("LICENSE" in error for error in check.check_artifact("crate", path)))

    def test_refuses_an_old_or_different_license_text(self) -> None:
        path = self.crate({"cmux-sdk-1.2.3/Cargo.toml": CARGO, "cmux-sdk-1.2.3/LICENSE": GPL + b"old\n"})
        self.assertTrue(any("differs" in error for error in check.check_artifact("crate", path)))

    def test_refuses_a_wrong_license_field(self) -> None:
        cargo = CARGO.replace(b"GPL-3.0-or-later", b"MIT")
        path = self.crate({"cmux-sdk-1.2.3/Cargo.toml": cargo, "cmux-sdk-1.2.3/LICENSE": GPL})
        self.assertTrue(any("GPL-3.0-or-later" in error for error in check.check_artifact("crate", path)))

    def test_refuses_compiled_code_without_notices(self) -> None:
        path = self.crate({"cmux-sdk-1.2.3/Cargo.toml": CARGO, "cmux-sdk-1.2.3/LICENSE": GPL, "cmux-sdk-1.2.3/native/libx.bin": ELF})
        self.assertTrue(any("compiled" in error for error in check.check_artifact("crate", path)))


class NpmTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def test_accepts_the_packed_tarball(self) -> None:
        path = _tar_gz(self.tmp / "p.tgz", {"package/package.json": PACKAGE_JSON, "package/LICENSE": GPL, "package/dist/src/index.js": b""})
        self.assertEqual(check.check_artifact("npm", path), [])

    def test_refuses_a_missing_license_and_a_native_addon(self) -> None:
        path = _tar_gz(self.tmp / "p.tgz", {"package/package.json": PACKAGE_JSON, "package/dist/addon.node": ELF})
        errors = check.check_artifact("npm", path)
        self.assertTrue(any("LICENSE" in error for error in errors), errors)
        self.assertTrue(any("compiled" in error for error in errors), errors)


class PythonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def wheel(self, extra: dict[str, bytes], *, wheel: bytes = WHEEL, license_text: bytes | None = GPL) -> Path:
        files = {
            "cmux/__init__.py": b"",
            "cmux_sdk-1.2.3.dist-info/METADATA": METADATA,
            "cmux_sdk-1.2.3.dist-info/WHEEL": wheel,
        }
        if license_text is not None:
            files["cmux_sdk-1.2.3.dist-info/licenses/LICENSE"] = license_text
        files.update(extra)
        return _zip(self.tmp / "cmux_sdk-1.2.3-py3-none-any.whl", files)

    def test_accepts_a_pure_wheel(self) -> None:
        self.assertEqual(check.check_artifact("wheel", self.wheel({})), [])

    def test_refuses_a_wheel_without_license(self) -> None:
        self.assertTrue(check.check_artifact("wheel", self.wheel({}, license_text=None)))

    def test_refuses_a_platform_wheel(self) -> None:
        wheel = WHEEL.replace(b"py3-none-any", b"cp312-cp312-manylinux_2_17_x86_64").replace(b"true", b"false")
        errors = check.check_artifact("wheel", self.wheel({"cmux/_native.so": ELF}, wheel=wheel))
        self.assertTrue(any("compiled" in error for error in errors), errors)
        self.assertTrue(any("py3-none-any" in error for error in errors), errors)

    def test_accepts_and_refuses_source_distributions(self) -> None:
        good = _tar_gz(self.tmp / "cmux_sdk-1.2.3.tar.gz", {"cmux_sdk-1.2.3/PKG-INFO": METADATA, "cmux_sdk-1.2.3/LICENSE": GPL})
        self.assertEqual(check.check_artifact("sdist", good), [])
        bad = _tar_gz(self.tmp / "bad.tar.gz", {"cmux_sdk-1.2.3/PKG-INFO": METADATA.replace(b"GPL-3.0-or-later", b"MIT")})
        self.assertGreaterEqual(len(check.check_artifact("sdist", bad)), 2)


class GoModuleTests(unittest.TestCase):
    def test_refuses_a_module_without_its_own_license(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            module = Path(tmp)
            (module / "go.mod").write_text("module example.com/x\n")
            self.assertTrue(any("LICENSE" in error for error in check.check_artifact("go-module", module)))
            (module / "LICENSE").write_bytes(GPL)
            self.assertEqual(check.check_artifact("go-module", module), [])


if __name__ == "__main__":
    unittest.main()
