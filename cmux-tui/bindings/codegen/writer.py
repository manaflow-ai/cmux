"""Safe deterministic staging, checking, and writing of generated SDK files."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    try:
        from .ir import SdkIR
    except ImportError:
        from ir import SdkIR

MANIFEST_FILENAME = ".cmux-sdk-manifest.json"
MANIFEST_FORMAT = 1
_LANGUAGE = re.compile(r"^[a-z][a-z0-9_+-]*$")


class GenerationError(RuntimeError):
    pass


class NondeterministicGenerationError(GenerationError):
    pass


class GeneratedOutputDrift(GenerationError):
    def __init__(self, language: str, problems: tuple[str, ...]):
        self.language = language
        self.problems = problems
        super().__init__(
            f"{language} generated output is stale:\n"
            + "\n".join(f"- {problem}" for problem in problems)
        )


@dataclass(frozen=True, slots=True)
class Emitter:
    """Registration exported by each ``emit_<language>.py`` module."""

    language: str
    output_root: PurePosixPath
    render: Callable[
        ["SdkIR"], Mapping[str | PurePosixPath, str | bytes | bytearray]
    ]

    def __post_init__(self) -> None:
        if not _LANGUAGE.fullmatch(self.language):
            raise ValueError(f"invalid emitter language {self.language!r}")
        _validate_relative_path(self.output_root, label="emitter output root")
        if str(self.output_root) in {"", "."}:
            raise ValueError("emitter output root must not be empty")
        if not callable(self.render):
            raise TypeError("emitter render must be callable")


@dataclass(frozen=True, slots=True)
class GeneratedTree:
    emitter: Emitter
    files: Mapping[PurePosixPath, bytes]


def _validate_relative_path(path: PurePosixPath, *, label: str) -> None:
    if path.is_absolute() or not path.parts:
        raise GenerationError(f"{label} must be a non-empty relative POSIX path: {path}")
    if any(part in {"", ".", ".."} for part in path.parts):
        raise GenerationError(f"{label} may not contain '.', '..', or empty parts: {path}")


def _normalize_content(value: str | bytes | bytearray, *, path: PurePosixPath) -> bytes:
    if isinstance(value, str):
        return value.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    raise GenerationError(
        f"generated file {path} has unsupported content type {type(value).__name__}"
    )


def render_files(emitter: Emitter, ir: "SdkIR") -> dict[PurePosixPath, bytes]:
    """Render and normalize one emitter without touching the filesystem."""

    rendered = emitter.render(ir)
    if not isinstance(rendered, Mapping):
        raise GenerationError(
            f"{emitter.language} emitter must return a mapping, "
            f"got {type(rendered).__name__}"
        )
    files: dict[PurePosixPath, bytes] = {}
    for raw_path, content in rendered.items():
        if not isinstance(raw_path, (str, PurePosixPath)):
            raise GenerationError(
                f"{emitter.language} emitter returned a non-path key "
                f"{type(raw_path).__name__}"
            )
        path = PurePosixPath(raw_path)
        _validate_relative_path(path, label="generated file path")
        if path.name == MANIFEST_FILENAME:
            raise GenerationError(
                f"{emitter.language} emitter may not generate reserved "
                f"{MANIFEST_FILENAME}"
            )
        if path in files:
            raise GenerationError(
                f"{emitter.language} emitter generated duplicate path {path}"
            )
        files[path] = _normalize_content(content, path=path)
    if not files:
        raise GenerationError(f"{emitter.language} emitter generated no files")
    return {path: files[path] for path in sorted(files, key=str)}


def _manifest_bytes(
    emitter: Emitter, ir: "SdkIR", files: Mapping[PurePosixPath, bytes]
) -> bytes:
    manifest = {
        "format": MANIFEST_FORMAT,
        "language": emitter.language,
        "schema_version": ir.schema_version,
        "mux_protocol": ir.mux_protocol,
        "ir_sha256": ir.ir_sha256,
        "files": [
            {
                "path": path.as_posix(),
                "sha256": hashlib.sha256(content).hexdigest(),
                "size": len(content),
            }
            for path, content in sorted(files.items(), key=lambda item: str(item[0]))
        ],
    }
    return (
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
        + b"\n"
    )


def _materialize(root: Path, files: Mapping[PurePosixPath, bytes]) -> None:
    for path, content in sorted(files.items(), key=lambda item: str(item[0])):
        destination = root.joinpath(*path.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)


def _tree_snapshot(root: Path) -> dict[PurePosixPath, bytes]:
    return {
        PurePosixPath(path.relative_to(root).as_posix()): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def generate_twice(emitter: Emitter, ir: "SdkIR") -> GeneratedTree:
    """Stage two independent renders and require byte-for-byte equality."""

    with tempfile.TemporaryDirectory(prefix=f"cmux-sdk-{emitter.language}-") as raw_temp:
        temp = Path(raw_temp)
        snapshots: list[dict[PurePosixPath, bytes]] = []
        for pass_number in (1, 2):
            rendered = render_files(emitter, ir)
            rendered[PurePosixPath(MANIFEST_FILENAME)] = _manifest_bytes(
                emitter, ir, rendered
            )
            pass_root = temp / f"pass-{pass_number}"
            _materialize(pass_root, rendered)
            snapshots.append(_tree_snapshot(pass_root))
        if snapshots[0] != snapshots[1]:
            paths = sorted(set(snapshots[0]) | set(snapshots[1]), key=str)
            changed = [
                str(path)
                for path in paths
                if snapshots[0].get(path) != snapshots[1].get(path)
            ]
            raise NondeterministicGenerationError(
                f"{emitter.language} emitter is nondeterministic; "
                f"byte differences: {', '.join(changed)}"
            )
        return GeneratedTree(emitter=emitter, files=snapshots[0])


def _root_path(bindings_root: Path, emitter: Emitter) -> Path:
    root = bindings_root.joinpath(*emitter.output_root.parts)
    bindings_resolved = bindings_root.resolve()
    root_resolved = root.resolve(strict=False)
    try:
        root_resolved.relative_to(bindings_resolved)
    except ValueError as error:
        raise GenerationError(
            f"{emitter.language} output root escapes bindings root: {root}"
        ) from error
    return root


def _safe_destination(root: Path, path: PurePosixPath) -> Path:
    destination = root.joinpath(*path.parts)
    root_resolved = root.resolve(strict=False)
    destination_resolved = destination.resolve(strict=False)
    try:
        destination_resolved.relative_to(root_resolved)
    except ValueError as error:
        raise GenerationError(
            f"generated path traverses a symlink outside its output root: {path}"
        ) from error
    return destination


def _manifest_owned_paths(root: Path, *, language: str) -> set[PurePosixPath]:
    manifest_path = _safe_destination(root, PurePosixPath(MANIFEST_FILENAME))
    if not manifest_path.exists():
        return set()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GenerationError(f"cannot read generated manifest {manifest_path}: {error}")
    if not isinstance(manifest, dict):
        raise GenerationError(f"generated manifest {manifest_path} must be an object")
    if manifest.get("format") != MANIFEST_FORMAT:
        raise GenerationError(
            f"generated manifest {manifest_path} has unsupported format "
            f"{manifest.get('format')!r}"
        )
    if manifest.get("language") != language:
        raise GenerationError(
            f"generated manifest {manifest_path} belongs to "
            f"{manifest.get('language')!r}, not {language!r}"
        )
    raw_files = manifest.get("files")
    if not isinstance(raw_files, list):
        raise GenerationError(f"generated manifest {manifest_path} files must be an array")
    owned: set[PurePosixPath] = set()
    for index, item in enumerate(raw_files):
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise GenerationError(
                f"generated manifest {manifest_path} files[{index}] must contain path"
            )
        path = PurePosixPath(item["path"])
        _validate_relative_path(path, label="manifest owned path")
        if path.name == MANIFEST_FILENAME:
            raise GenerationError(
                f"generated manifest {manifest_path} may not own itself"
            )
        owned.add(path)
    return owned


def check_generated(bindings_root: str | Path, tree: GeneratedTree) -> None:
    """Require the working tree to exactly match staged generated output."""

    root = _root_path(Path(bindings_root), tree.emitter)
    problems: list[str] = []
    for path, expected in sorted(tree.files.items(), key=lambda item: str(item[0])):
        destination = _safe_destination(root, path)
        if not destination.is_file():
            problems.append(f"missing {path}")
            continue
        try:
            actual = destination.read_bytes()
        except OSError as error:
            problems.append(f"cannot read {path}: {error}")
            continue
        if actual != expected:
            problems.append(f"changed {path}")

    expected_owned = set(tree.files) - {PurePosixPath(MANIFEST_FILENAME)}
    prior_owned = _manifest_owned_paths(root, language=tree.emitter.language)
    for path in sorted(prior_owned - expected_owned, key=str):
        problems.append(f"stale owned file {path}")
    if problems:
        raise GeneratedOutputDrift(tree.emitter.language, tuple(problems))


def _atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        mode = 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def _prune_empty_parents(path: Path, *, stop: Path) -> None:
    parent = path.parent
    while parent != stop:
        try:
            parent.rmdir()
        except OSError:
            return
        parent = parent.parent


def write_generated(bindings_root: str | Path, tree: GeneratedTree) -> None:
    """Atomically update generated files and remove only manifest-owned stale files."""

    root = _root_path(Path(bindings_root), tree.emitter)
    prior_owned = _manifest_owned_paths(root, language=tree.emitter.language)
    expected_owned = set(tree.files) - {PurePosixPath(MANIFEST_FILENAME)}

    # Write source files first and the ownership manifest last. An interruption
    # therefore leaves --check failing instead of claiming a partial write is current.
    for path, content in sorted(tree.files.items(), key=lambda item: str(item[0])):
        if path.name == MANIFEST_FILENAME:
            continue
        _atomic_write(_safe_destination(root, path), content)

    for path in sorted(prior_owned - expected_owned, key=str):
        destination = _safe_destination(root, path)
        if destination.is_file() or destination.is_symlink():
            destination.unlink()
            _prune_empty_parents(destination, stop=root)

    manifest = tree.files[PurePosixPath(MANIFEST_FILENAME)]
    _atomic_write(
        _safe_destination(root, PurePosixPath(MANIFEST_FILENAME)),
        manifest,
    )
