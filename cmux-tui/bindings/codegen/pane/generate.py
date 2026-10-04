#!/usr/bin/env python3
"""Generate or check a Go pane-protocol package from the pane-protocol IR.

    python3 cmux-tui/bindings/codegen/pane/generate.py --write \\
        --ir cmux-tui/spec/pane-protocol.json \\
        --out path/to/hellopane --package hellopane \\
        --provider-ns com.example.hello

--check exits 1 when the files in --out differ from what the IR produces.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from codegen.pane.emit_go import HEADER_MARK, render  # noqa: E402
from codegen.pane.ir import PaneIRError, load_pane_ir  # noqa: E402


def _generated_files(out: Path) -> set[str]:
    if not out.is_dir():
        return set()
    names = set()
    for path in out.glob("*.go"):
        with path.open(encoding="utf-8") as handle:
            if handle.readline().rstrip("\n") == HEADER_MARK:
                names.add(path.name)
    return names


def run(*, ir_path: Path, out: Path, package: str, provider_ns: tuple[str, ...], mode: str) -> list[str]:
    """Write or check; return a list of drift problems (empty when clean)."""

    files = render(load_pane_ir(ir_path), package=package, provider_namespaces=provider_ns)
    problems: list[str] = []
    stale = _generated_files(out) - set(files)
    if mode == "write":
        out.mkdir(parents=True, exist_ok=True)
        for name, source in files.items():
            target = out / name
            if not target.exists() or target.read_text(encoding="utf-8") != source:
                target.write_text(source, encoding="utf-8")
        for name in stale:
            (out / name).unlink()
        return problems
    for name, source in files.items():
        target = out / name
        if not target.exists():
            problems.append(f"missing {target}")
        elif target.read_text(encoding="utf-8") != source:
            problems.append(f"stale {target}")
    problems += [f"unexpected generated file {out / name}" for name in sorted(stale)]
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--ir", type=Path, required=True, help="pane-protocol IR JSON")
    parser.add_argument("--out", type=Path, required=True, help="output package directory")
    parser.add_argument("--package", required=True, help="Go package name")
    parser.add_argument(
        "--provider-ns",
        action="append",
        default=[],
        metavar="NS",
        help="namespace this package serves (repeatable); omit for a client-only package",
    )
    args = parser.parse_args(argv)
    try:
        problems = run(
            ir_path=args.ir,
            out=args.out,
            package=args.package,
            provider_ns=tuple(args.provider_ns),
            mode="write" if args.write else "check",
        )
    except (PaneIRError, ValueError, OSError) as error:
        print(f"pane Go generation failed: {error}", file=sys.stderr)
        return 1
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
