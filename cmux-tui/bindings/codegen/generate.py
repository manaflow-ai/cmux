#!/usr/bin/env python3
"""Generate or verify all cmux TUI language SDK wire layers."""

from __future__ import annotations

import argparse
import importlib
import sys
from collections.abc import Callable, Iterable
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import Any

if __package__ in {None, ""}:
    _CODEGEN_DIR = Path(__file__).resolve().parent
    sys.path.insert(0, str(_CODEGEN_DIR.parent))
    from codegen.ir import SdkIR, load_ir
    from codegen.validate import ValidationError
    from codegen.writer import (
        Emitter,
        GenerationError,
        check_generated,
        generate_twice,
        write_generated,
    )
else:
    from .ir import SdkIR, load_ir
    from .validate import ValidationError
    from .writer import (
        Emitter,
        GenerationError,
        check_generated,
        generate_twice,
        write_generated,
    )

CODEGEN_DIR = Path(__file__).resolve().parent
DEFAULT_BINDINGS_ROOT = CODEGEN_DIR.parent
DEFAULT_SCHEMA = DEFAULT_BINDINGS_ROOT.parent / "spec" / "sdk-schema.json"

EmitterLoader = Callable[[str], Emitter]


def available_languages(codegen_dir: Path = CODEGEN_DIR) -> tuple[str, ...]:
    return tuple(
        sorted(
            path.stem.removeprefix("emit_")
            for path in codegen_dir.glob("emit_*.py")
            if path.stem != "emit_"
        )
    )


def _coerce_emitter(value: Any, *, requested_language: str) -> Emitter:
    if isinstance(value, Emitter):
        emitter = value
    else:
        try:
            emitter = Emitter(
                language=value.language,
                output_root=PurePosixPath(value.output_root),
                render=value.render,
            )
        except (AttributeError, TypeError, ValueError) as error:
            raise GenerationError(
                f"emit_{requested_language}.py EMITTER does not implement "
                "writer.Emitter"
            ) from error
    if emitter.language != requested_language:
        raise GenerationError(
            f"emit_{requested_language}.py registered language "
            f"{emitter.language!r}"
        )
    return emitter


def load_emitter(language: str) -> Emitter:
    module_name = f"codegen.emit_{language}"
    try:
        module: ModuleType = importlib.import_module(module_name)
    except ModuleNotFoundError as error:
        if error.name == module_name:
            raise GenerationError(f"unknown SDK language {language!r}") from error
        raise
    try:
        value = module.EMITTER
    except AttributeError as error:
        raise GenerationError(f"{module_name} does not export EMITTER") from error
    return _coerce_emitter(value, requested_language=language)


def selected_languages(
    requested: Iterable[str], *, discovered: Iterable[str] | None = None
) -> tuple[str, ...]:
    available = tuple(
        sorted(set(discovered if discovered is not None else available_languages()))
    )
    requested_set = set(requested)
    if not requested_set:
        if not available:
            raise GenerationError("no language emitters are installed")
        return available
    unknown = sorted(requested_set - set(available))
    if unknown:
        raise GenerationError(
            "unknown SDK language(s): "
            + ", ".join(unknown)
            + "; available: "
            + (", ".join(available) if available else "(none)")
        )
    return tuple(sorted(requested_set))


def run_generation(
    *,
    mode: str,
    schema: str | Path,
    bindings_root: str | Path,
    languages: Iterable[str],
    emitter_loader: EmitterLoader = load_emitter,
    discovered_languages: Iterable[str] | None = None,
) -> tuple[str, ...]:
    """Run generation for tests and the command-line entry point."""

    if mode not in {"write", "check"}:
        raise ValueError(f"unknown generation mode {mode!r}")
    ir: SdkIR = load_ir(schema)
    chosen = selected_languages(languages, discovered=discovered_languages)
    trees = []
    for language in chosen:
        emitter = emitter_loader(language)
        trees.append(generate_twice(emitter, ir))
    completed: list[str] = []
    for language, tree in zip(chosen, trees, strict=True):
        if mode == "write":
            write_generated(bindings_root, tree)
        else:
            check_generated(bindings_root, tree)
        completed.append(language)
    return tuple(completed)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="update generated files")
    mode.add_argument(
        "--check",
        action="store_true",
        help="fail when committed generated files differ",
    )
    parser.add_argument(
        "--language",
        action="append",
        default=[],
        metavar="NAME",
        help="generate one language; repeat to select several (default: all)",
    )
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--bindings-root", type=Path, default=DEFAULT_BINDINGS_ROOT)
    parser.add_argument(
        "--list-languages",
        action="store_true",
        help="print installed emitter names and exit",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.list_languages:
        for language in available_languages():
            print(language)
        return 0
    if not arguments.write and not arguments.check:
        parser.error("one of --write or --check is required")
    mode = "write" if arguments.write else "check"
    try:
        completed = run_generation(
            mode=mode,
            schema=arguments.schema,
            bindings_root=arguments.bindings_root,
            languages=arguments.language,
        )
    except (GenerationError, ValidationError, ValueError) as error:
        print(f"SDK generation failed: {error}", file=sys.stderr)
        return 1
    verb = "wrote" if mode == "write" else "checked"
    for language in completed:
        print(f"{verb} {language}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
