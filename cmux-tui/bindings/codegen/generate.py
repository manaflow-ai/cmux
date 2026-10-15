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

# emit_*.py modules that are not SDK languages. `--write`/`--check` never run
# them; `emit_cpp_value.py` runs only through `--cpp-value`.
NON_SDK_EMITTERS = frozenset({"cpp_value"})


def available_languages(codegen_dir: Path = CODEGEN_DIR) -> tuple[str, ...]:
    return tuple(
        sorted(
            path.stem.removeprefix("emit_")
            for path in codegen_dir.glob("emit_*.py")
            if path.stem != "emit_"
            and path.stem.removeprefix("emit_") not in NON_SDK_EMITTERS
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
    cpp_value = parser.add_argument_group(
        "base::Value codec for cmux-browser (emit_cpp_value.py)"
    )
    cpp_value.add_argument(
        "--cpp-value",
        action="store_true",
        help=(
            "write cmux_daemon_types.{h,cc} for the commands and events in "
            "--allowlist into --out (with --check: fail when they differ); "
            "the SDK bindings are not touched"
        ),
    )
    cpp_value.add_argument("--allowlist", type=Path, metavar="FILE")
    cpp_value.add_argument("--out", type=Path, metavar="DIR")
    cpp_value.add_argument(
        "--include-path",
        default=None,
        metavar="PATH",
        help=(
            "include path of the generated header, also its include guard "
            "(default: third_party/cmux_tui_spec/cmux_daemon_types.h)"
        ),
    )
    return parser


def _load_cpp_value() -> ModuleType:
    if __package__ in {None, ""}:
        return importlib.import_module("codegen.emit_cpp_value")
    return importlib.import_module(f"{__package__}.emit_cpp_value")


def run_cpp_value(arguments: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    if arguments.language:
        parser.error("--cpp-value does not take --language")
    if arguments.allowlist is None or arguments.out is None:
        parser.error("--cpp-value needs --allowlist FILE and --out DIR")
    emit_cpp_value = _load_cpp_value()
    mode = "check" if arguments.check else "write"
    include_path = arguments.include_path or emit_cpp_value.DEFAULT_INCLUDE_PATH
    try:
        changed = emit_cpp_value.run(
            ir=load_ir(arguments.schema),
            allowlist_path=arguments.allowlist,
            out_dir=arguments.out,
            mode=mode,
            include_path=include_path,
        )
    except (GenerationError, ValidationError, ValueError) as error:
        print(f"cpp-value generation failed: {error}", file=sys.stderr)
        return 1
    if mode == "check":
        print(f"checked cpp-value {arguments.out}")
    else:
        print(f"wrote cpp-value {arguments.out} ({len(changed)} changed)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.list_languages:
        for language in available_languages():
            print(language)
        return 0
    if arguments.cpp_value:
        return run_cpp_value(arguments, parser)
    if arguments.allowlist or arguments.out or arguments.include_path:
        parser.error("--allowlist, --out and --include-path need --cpp-value")
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
    # The page clients' copy of spec/page-router.json (page-router.md).
    if arguments.bindings_root == DEFAULT_BINDINGS_ROOT and not arguments.language:
        if __package__ in {None, ""}:
            from codegen import page_router
        else:
            from . import page_router
        return page_router.main([f"--{mode}"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
