#!/usr/bin/env python3
"""Generate the CmuxNextDaemon request types that swift_app/bindings.json lists, or check that they generate.

    python3 cmux-tui/bindings/codegen/swift_app/generate.py --out DIR
    python3 cmux-tui/bindings/codegen/swift_app/generate.py --check

The files are build output, never committed (scripts/ci/generated_files_guard.py). The SwiftPM build tool
plugin Packages/macOS/CmuxNext/Plugins/DaemonWireTypes runs `--out <its work folder>` before every build of
the CmuxNextDaemon target, and SwiftPM compiles what it writes there. It is the only writer: SwiftPM compiles
every .swift file under a target's folder, so a second copy there would fail with "invalid redeclaration".
`--out` therefore refuses a folder inside `sources_root` (the target's folder) or anywhere under a package's
`Sources`.

--out DIR  write every generated file under DIR and delete the files in DIR an earlier run wrote that are no
           longer generated (a file is ours when its first line is emit.HEADER_MARK).
--check    render every family in a temporary folder (so a schema or bindings change that cannot generate
           fails here, not in the build), and refuse a generated type that a hand-written file under
           sources_root still declares. Agents run it before a push; codegen/generate.py runs it with the SDKs.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from codegen.ir import load_ir  # noqa: E402
from codegen.swift_app.emit import HEADER_MARK, BindingError, render  # noqa: E402
from codegen.validate import ValidationError  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_SCHEMA = REPO_ROOT / "cmux-tui" / "spec" / "sdk-schema.json"
DEFAULT_BINDINGS = Path(__file__).resolve().with_name("bindings.json")
SUFFIX = ".generated.swift"
_DECLARATION = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|nonisolated|final|indirect)\s+)*"
    r"(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)",
    re.M,
)


def load_bindings(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BindingError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise BindingError(f"{path} must be an object")
    return value


def sources_root(repo_root: Path, bindings: dict[str, Any]) -> Path:
    """The target folder whose hand-written Swift the generated types join (the redeclaration check reads it)."""
    raw = bindings.get("sources_root")
    if not isinstance(raw, str) or not raw:
        raise BindingError("bindings need sources_root, the repository-relative folder of the target")
    relative = PurePosixPath(raw)
    if relative.is_absolute() or ".." in relative.parts:
        raise BindingError(f"sources_root {raw!r} must stay inside the repository")
    return repo_root.joinpath(*relative.parts)


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def check_out_folder(out: Path, repo_root: Path, bindings: dict[str, Any]) -> None:
    """Refuse an --out that SwiftPM would compile a second time (a target's folder or any package Sources)."""
    if _inside(out, sources_root(repo_root, bindings)):
        raise BindingError(f"--out {out} is inside sources_root; generated files there would be compiled twice")
    resolved = out.resolve()
    if _inside(resolved, repo_root) and "Sources" in resolved.relative_to(repo_root.resolve()).parts:
        raise BindingError(f"--out {out} is inside a package's Sources folder")


def owned_files(root: Path) -> set[str]:
    if not root.is_dir():
        return set()
    owned = set()
    for path in root.rglob("*" + SUFFIX):
        try:
            with path.open(encoding="utf-8") as handle:
                if handle.readline().rstrip("\n") == HEADER_MARK:
                    owned.add(path.relative_to(root).as_posix())
        except (OSError, UnicodeError):
            continue
    return owned


def hand_written_declarations(root: Path) -> dict[str, str]:
    """{type name: repository-relative file} of the top-level types the hand-written Swift under ROOT declares."""
    found: dict[str, str] = {}
    if not root.is_dir():
        return found
    for path in sorted(root.rglob("*.swift")):
        if path.name.endswith(SUFFIX):
            continue
        for name in _DECLARATION.findall(path.read_text(encoding="utf-8")):
            found.setdefault(name, path.as_posix())
    return found


def write(files: dict[str, str], out: Path) -> None:
    owned = owned_files(out)
    for relative, content in files.items():
        target = out / relative
        if target.exists() and relative not in owned:
            raise BindingError(f"{target} exists and is not generated by this emitter; refusing to replace it")
        if not target.exists() or target.read_text(encoding="utf-8") != content:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
    for relative in sorted(owned - set(files)):
        stale = out / relative
        stale.unlink()
        parent = stale.parent
        while parent != out and parent.is_dir() and not any(parent.iterdir()):
            parent.rmdir()
            parent = parent.parent


def run(*, mode: str, schema: Path, bindings: Path, repo_root: Path, out: Path | None = None) -> list[str]:
    """--out writes and returns []; --check returns the problems (empty when the families generate cleanly)."""
    loaded = load_bindings(bindings)
    files = render(load_ir(schema), loaded)
    if mode == "out":
        if out is None:
            raise ValueError("--out needs a folder")
        check_out_folder(out, Path(repo_root), loaded)
        write(files, out)
        return []
    if mode != "check":
        raise ValueError(f"unknown mode {mode!r}")
    with tempfile.TemporaryDirectory(prefix="cmux-swift-app-") as temporary:
        write(files, Path(temporary))
    declared = hand_written_declarations(sources_root(Path(repo_root), loaded))
    problems = []
    for relative in sorted(files):
        name = PurePosixPath(relative).name.removesuffix(SUFFIX)
        if name in declared:
            problems.append(f"{name} is generated ({relative}) and still declared by hand in {declared[name]}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--out", type=Path, metavar="DIR", help="write the generated Swift files under DIR")
    mode.add_argument("--check", action="store_true", help="check that every family generates and is not also hand-written")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--bindings", type=Path, default=DEFAULT_BINDINGS)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    arguments = parser.parse_args(argv)
    chosen = "check" if arguments.check else "out"
    try:
        problems = run(mode=chosen, schema=arguments.schema, bindings=arguments.bindings,
                       repo_root=arguments.repo_root, out=arguments.out)
    except (BindingError, ValidationError, ValueError, OSError) as error:
        print(f"Swift app codegen failed: {error}", file=sys.stderr)
        return 1
    if problems:
        print("Swift app codegen check failed:\n" + "\n".join(f"- {problem}" for problem in problems), file=sys.stderr)
        return 1
    print(f"{'checked' if chosen == 'check' else 'wrote'} swift-app")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
