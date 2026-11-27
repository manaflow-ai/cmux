#!/usr/bin/env python3
"""Check that every published cmux SDK package ships the cmux GPL text and no compiled code.

The SDKs are source only: the crates cmux-sdk and cmux-sidebar, the npm package
cmux-sdk, the PyPI package cmux-sdk (wheel and sdist), and the Go modules under
cmux-tui/bindings/go and cmux-tui/bindings/go-pane, and the Java SDK jar
(cmux-tui/bindings/java, not yet published; scripts/build.sh checks the jar it
builds). Their dependencies come from
the package manager, so they ship no third-party code and need no third-party
notices. They must ship LICENSE (byte-equal to cmux-tui/dist/npm/cmux/LICENSE,
the GPL text every cmux-tui package uses) and declare GPL-3.0-or-later.

A package that starts to ship a compiled file (native library, addon, wasm,
executable) fails closed: it then links code whose notices this check cannot
prove, and it needs THIRD_PARTY_LICENSES.md from cmux-tui/dist/scripts/package_notices.py
and a contract like the cmux-tui packages before it may publish.

Usage:
  check_package_license.py repo
  check_package_license.py crate|npm|wheel|sdist|jar PATH
  check_package_license.py go-module DIR
"""

from __future__ import annotations

import argparse
import email.parser
import json
import sys
import tarfile
import tomllib
import xml.etree.ElementTree as ElementTree
import zipfile
from dataclasses import dataclass
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
LICENSE_SOURCE = REPO / "cmux-tui/dist/npm/cmux/LICENSE"
EXPRESSION = "GPL-3.0-or-later"

# Magic numbers of compiled code: ELF, Mach-O (32/64, both byte orders, fat), PE/COFF,
# WebAssembly, ar archives (static libraries).
MAGICS = (
    b"\x7fELF",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"MZ",
    b"\0asm",
    b"!<arch>\n",
)
COMPILED_SUFFIXES = (".so", ".dylib", ".dll", ".exe", ".node", ".wasm", ".a", ".lib", ".pyd", ".o")


@dataclass(frozen=True)
class Package:
    name: str
    directory: str
    kind: str  # crate | npm | pypi | go | maven


PACKAGES = (
    Package("cmux-sdk (crate)", "cmux-tui/bindings/rust", "crate"),
    Package("cmux-sidebar (crate)", "cmux-tui/bindings/rust-sidebar", "crate"),
    Package("cmux-sdk (npm)", "cmux-tui/bindings/typescript", "npm"),
    Package("cmux-sdk (pypi)", "cmux-tui/bindings/python", "pypi"),
    Package("go", "cmux-tui/bindings/go", "go"),
    Package("go-pane", "cmux-tui/bindings/go-pane", "go"),
    Package("cmux-java-sdk (maven)", "cmux-tui/bindings/java", "maven"),
)
# A JVM class file starts with 0xCAFEBABE, like a fat Mach-O: a jar may hold .class
# files with that magic, nothing else compiled.
CLASS_MAGIC = b"\xca\xfe\xba\xbe"


def _is_class_file(data: bytes) -> bool:
    # After the magic, a class file has minor and major version (major >= 45, Java 1.0);
    # a fat Mach-O has its architecture count (a few).
    return data.startswith(CLASS_MAGIC) and len(data) >= 8 and int.from_bytes(data[4:8], "big") >= 45


def _gpl() -> bytes:
    return LICENSE_SOURCE.read_bytes()


def _license_errors(label: str, data: bytes | None) -> list[str]:
    if data is None:
        return [f"{label}: LICENSE is missing (copy {LICENSE_SOURCE.relative_to(REPO)})"]
    if data != _gpl():
        return [f"{label}: LICENSE differs from {LICENSE_SOURCE.relative_to(REPO)} (old or wrong text)"]
    return []


def _compiled(name: str, head: bytes) -> bool:
    return name.endswith(COMPILED_SUFFIXES) or any(head.startswith(magic) for magic in MAGICS)


def _compiled_error(label: str, name: str) -> str:
    return (
        f"{label}: ships compiled file {name}; a package with compiled code needs "
        "THIRD_PARTY_LICENSES.md from cmux-tui/dist/scripts/package_notices.py and a package "
        "contract before it may publish"
    )


def _metadata_errors(label: str, text: bytes, *, need_license_file: bool) -> list[str]:
    message = email.parser.BytesParser().parsebytes(text, headersonly=True)
    errors = []
    if message.get("License-Expression") != EXPRESSION:
        errors.append(f"{label}: License-Expression is {message.get('License-Expression')!r}, not {EXPRESSION}")
    if need_license_file and "LICENSE" not in (message.get_all("License-File") or []):
        errors.append(f"{label}: METADATA has no License-File: LICENSE")
    return errors


def _read_tar(path: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    with tarfile.open(path, "r:*") as archive:
        for member in archive.getmembers():
            if member.isfile():
                handle = archive.extractfile(member)
                files[member.name] = handle.read() if handle else b""
    return files


def _single_root(label: str, files: dict[str, bytes]) -> tuple[str | None, list[str]]:
    roots = {name.split("/", 1)[0] for name in files}
    if len(roots) != 1:
        return None, [f"{label}: expected one top-level directory, found {sorted(roots)}"]
    return roots.pop(), []


def check_crate(path: Path) -> list[str]:
    label = path.name
    files = _read_tar(path)
    root, errors = _single_root(label, files)
    if root is None:
        return errors
    errors += _license_errors(label, files.get(f"{root}/LICENSE"))
    manifest = files.get(f"{root}/Cargo.toml")
    if manifest is None:
        errors.append(f"{label}: Cargo.toml is missing")
    else:
        package = tomllib.loads(manifest.decode()).get("package", {})
        if package.get("license") != EXPRESSION:
            errors.append(f"{label}: Cargo.toml license is {package.get('license')!r}, not {EXPRESSION}")
    errors += [_compiled_error(label, name) for name, data in sorted(files.items()) if _compiled(name, data[:8])]
    return errors


def check_npm(path: Path) -> list[str]:
    label = path.name
    files = _read_tar(path)
    errors = _license_errors(label, files.get("package/LICENSE"))
    manifest = files.get("package/package.json")
    if manifest is None:
        errors.append(f"{label}: package/package.json is missing")
    elif json.loads(manifest).get("license") != EXPRESSION:
        errors.append(f"{label}: package.json license is not {EXPRESSION}")
    errors += [_compiled_error(label, name) for name, data in sorted(files.items()) if _compiled(name, data[:8])]
    return errors


def check_wheel(path: Path) -> list[str]:
    label = path.name
    with zipfile.ZipFile(path) as archive:
        files = {name: archive.read(name) for name in archive.namelist() if not name.endswith("/")}
    dist_infos = {name.split("/", 1)[0] for name in files if name.split("/", 1)[0].endswith(".dist-info")}
    if len(dist_infos) != 1:
        return [f"{label}: expected one .dist-info directory, found {sorted(dist_infos)}"]
    dist_info = dist_infos.pop()
    errors = _license_errors(label, files.get(f"{dist_info}/licenses/LICENSE"))
    errors += _metadata_errors(label, files.get(f"{dist_info}/METADATA", b""), need_license_file=True)
    wheel = email.parser.BytesParser().parsebytes(files.get(f"{dist_info}/WHEEL", b""), headersonly=True)
    if wheel.get_all("Tag") != ["py3-none-any"] or wheel.get("Root-Is-Purelib") != "true":
        errors.append(f"{label}: the SDK wheel must be pure (Tag py3-none-any, Root-Is-Purelib true)")
    errors += [_compiled_error(label, name) for name, data in sorted(files.items()) if _compiled(name, data[:8])]
    return errors


def check_sdist(path: Path) -> list[str]:
    label = path.name
    files = _read_tar(path)
    root, errors = _single_root(label, files)
    if root is None:
        return errors
    errors += _license_errors(label, files.get(f"{root}/LICENSE"))
    errors += _metadata_errors(label, files.get(f"{root}/PKG-INFO", b""), need_license_file=False)
    errors += [_compiled_error(label, name) for name, data in sorted(files.items()) if _compiled(name, data[:8])]
    return errors


def check_jar(path: Path) -> list[str]:
    label = path.name
    with zipfile.ZipFile(path) as archive:
        files = {name: archive.read(name) for name in archive.namelist() if not name.endswith("/")}
    errors = _license_errors(label, files.get("META-INF/LICENSE"))
    for name, data in sorted(files.items()):
        if name.endswith(".class") and _is_class_file(data):
            continue
        if _compiled(name, data[:8]):
            errors.append(_compiled_error(label, name))
    return errors


def _directory_files(directory: Path) -> dict[str, bytes]:
    files = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if path.is_file() and not any(part in {"node_modules", "dist", "target", "__pycache__", "build"} or part.endswith(".egg-info") for part in relative.split("/")[:-1]):
            with path.open("rb") as handle:
                files[relative] = handle.read(8)
    return files


def check_go_module(directory: Path) -> list[str]:
    # The Go module zip holds only the module directory (cmd/go copies the repository
    # root LICENSE only when the module has none), so the module carries its own text.
    label = directory.name
    license_path = directory / "LICENSE"
    errors = _license_errors(label, license_path.read_bytes() if license_path.is_file() else None)
    errors += [_compiled_error(label, name) for name, head in _directory_files(directory).items() if _compiled(name, head)]
    return errors


def _source_metadata_errors(package: Package, directory: Path) -> list[str]:
    label = package.name
    errors = []
    if package.kind == "crate":
        manifest = tomllib.loads((directory / "Cargo.toml").read_text())["package"]
        license_value = manifest.get("license")
        if license_value == {"workspace": True}:
            license_value = tomllib.loads((REPO / "cmux-tui/Cargo.toml").read_text())["workspace"]["package"]["license"]
        if license_value != EXPRESSION:
            errors.append(f"{label}: Cargo.toml license is {license_value!r}, not {EXPRESSION}")
        include = manifest.get("include")
        if include is not None and "LICENSE" not in include:
            errors.append(f"{label}: Cargo.toml include leaves LICENSE out of the crate")
        if any("LICENSE" in pattern for pattern in manifest.get("exclude", [])):
            errors.append(f"{label}: Cargo.toml exclude drops LICENSE")
    elif package.kind == "npm":
        if json.loads((directory / "package.json").read_text()).get("license") != EXPRESSION:
            errors.append(f"{label}: package.json license is not {EXPRESSION}")
    elif package.kind == "maven":
        root = ElementTree.parse(directory / "pom.xml").getroot()
        names = [(element.text or "").strip() for element in _license_elements(root)]
        if names != [EXPRESSION]:
            errors.append(f"{label}: pom.xml licenses are {names}, not [{EXPRESSION!r}]")
    elif package.kind == "pypi":
        project = tomllib.loads((directory / "pyproject.toml").read_text())["project"]
        if project.get("license") != EXPRESSION:
            errors.append(f"{label}: pyproject license is {project.get('license')!r}, not {EXPRESSION}")
        if "LICENSE" not in project.get("license-files", []):
            errors.append(f"{label}: pyproject license-files does not list LICENSE")
    return errors


def _license_elements(root: ElementTree.Element) -> list[ElementTree.Element]:
    """The <name> children of <licenses>/<license> in a pom."""
    names = []
    for licenses in (e for e in root if e.tag.rsplit("}", 1)[-1] == "licenses"):
        for license_element in licenses:
            names += [child for child in license_element if child.tag.rsplit("}", 1)[-1] == "name"]
    return names


def check_repository(repo: Path = REPO) -> list[str]:
    errors = []
    for package in PACKAGES:
        directory = repo / package.directory
        license_path = directory / "LICENSE"
        errors += _license_errors(package.name, license_path.read_bytes() if license_path.is_file() else None)
        errors += _source_metadata_errors(package, directory)
        errors += [_compiled_error(package.name, name) for name, head in _directory_files(directory).items() if _compiled(name, head)]
    return errors


CHECKS = {
    "crate": check_crate,
    "npm": check_npm,
    "wheel": check_wheel,
    "sdist": check_sdist,
    "go-module": check_go_module,
    "jar": check_jar,
}


def check_artifact(kind: str, path: Path) -> list[str]:
    return CHECKS[kind](Path(path))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=["repo", *CHECKS])
    parser.add_argument("paths", nargs="*", type=Path)
    arguments = parser.parse_args(argv)
    if arguments.kind == "repo":
        errors = check_repository()
    else:
        if not arguments.paths:
            parser.error(f"{arguments.kind} needs at least one path")
        errors = [error for path in arguments.paths for error in check_artifact(arguments.kind, path)]
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"SDK package license check passed ({arguments.kind})")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
