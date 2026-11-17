#!/usr/bin/env python3
"""The crates that hold most of cmux NEXT's `unsafe` keep a stated reason for each block.

Their Cargo.toml denies `clippy::undocumented_unsafe_blocks` (every `unsafe` block and
`unsafe impl` needs a `// SAFETY:` comment) and `clippy::missing_safety_doc` (every
`pub unsafe fn` needs a `# Safety` doc section). Three things the clippy job cannot see on
its own are checked here:

1. The deny stays in each crate's manifest.
2. Cargo cannot extend `[workspace.lints]`, so a crate that adds its own lints has to copy
   the workspace's. The copies must stay equal to the workspace table, or a lint added there
   later (await_holding_lock's proof lives in cmux-tui-core) would silently skip them.
3. clippy in CI runs on Linux, so code behind `cfg(target_os = "macos")` or `cfg(windows)`
   is never linted. A source scan finds an `unsafe` block or impl there with no SAFETY
   comment above it or above its statement. It is looser than clippy (a SAFETY comment
   anywhere in the comment block above the statement counts), so it never fails where
   clippy passes; it only catches a block with no reason at all.

    python3 .github/scripts/test_cmux_tui_unsafe_lints.py
"""

from __future__ import annotations

from pathlib import Path
import re
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT / "cmux-tui"
CRATES = WORKSPACE / "crates"

# Every crate whose unsafe is held to a stated reason.
DOCUMENTED = (
    "acpmux",
    "acpmux-client",
    "acpmux-core",
    "cmux-app-host",
    "cmux-rd-ffi",
    "cmux-rd-host",
    "cmux-rd-link",
    "cmux-tailnet",
    "cmux-tui-core",
    "cmux-wg",
    "cmux-wg-tun",
)

# Workspace members that inherited `[workspace.lints]` before the deny was added; they copy it.
MIRRORS = (
    "acpmux-client",
    "acpmux-core",
    "cmux-app-host",
    "cmux-rd-link",
    "cmux-tui-core",
    "cmux-wg",
    "cmux-wg-tun",
)

UNSAFE = re.compile(r"\bunsafe\s*(\{|impl\b)")


def manifest(crate: str) -> dict:
    return tomllib.loads((CRATES / crate / "Cargo.toml").read_text())


def undocumented(text: str) -> list[int]:
    """1-based lines of `unsafe` blocks/impls with no SAFETY comment above them or their statement."""
    lines = text.split("\n")
    hits = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(("//", "*", "/*")):
            continue
        match = UNSAFE.search(line)
        if not match:
            continue
        before = line[: match.start()]
        if before.count('"') % 2 == 1:
            continue
        if "SAFETY" in line or not _commented(lines, index):
            if "SAFETY" not in line:
                hits.append(index + 1)
    return hits


def _commented(lines: list[str], index: int) -> bool:
    start = index
    for _ in range(12):
        above = start - 1
        while above >= 0 and lines[above].strip().startswith(("//", "#[", "#!")):
            if "SAFETY" in lines[above]:
                return True
            above -= 1
        if start == 0:
            return False
        previous = lines[start - 1].strip()
        if not previous or previous.startswith("//") or previous.endswith((";", "}")):
            return False
        if previous.endswith("{") and not previous.endswith(("= {", "({", "=> {", "[{")):
            if not re.search(r"\b(if|else|match)\b", previous):
                return False
        start -= 1
    return False


class UnsafeLints(unittest.TestCase):
    def test_each_crate_denies_undocumented_unsafe(self) -> None:
        for crate in DOCUMENTED:
            with self.subTest(crate=crate):
                lints = manifest(crate).get("lints", {})
                self.assertNotIn(
                    "workspace", lints, "workspace = true cannot add the deny; copy the tables"
                )
                clippy = lints.get("clippy", {})
                self.assertEqual(clippy.get("undocumented_unsafe_blocks"), "deny")
                self.assertEqual(clippy.get("missing_safety_doc"), "deny")

    def test_copies_of_the_workspace_lints_stay_equal(self) -> None:
        workspace = tomllib.loads((WORKSPACE / "Cargo.toml").read_text())["workspace"]["lints"]
        for crate in MIRRORS:
            lints = manifest(crate)["lints"]
            for table, entries in workspace.items():
                for name, level in entries.items():
                    with self.subTest(crate=crate, lint=f"{table}::{name}"):
                        self.assertEqual(
                            lints.get(table, {}).get(name),
                            level,
                            f"{crate}/Cargo.toml copies [workspace.lints.{table}]; add {name} there",
                        )

    def test_every_unsafe_block_states_its_reason_on_every_os(self) -> None:
        missing = []
        for crate in DOCUMENTED:
            for path in sorted((CRATES / crate).rglob("*.rs")):
                if "target" in path.relative_to(CRATES / crate).parts:
                    continue
                for line in undocumented(path.read_text(errors="replace")):
                    missing.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertEqual(
            missing,
            [],
            "unsafe with no `// SAFETY:` comment saying why it is sound (clippy on Linux never "
            "compiles cfg(macos)/cfg(windows) code):\n  " + "\n  ".join(missing),
        )

    def test_the_scan_catches_a_block_with_no_reason(self) -> None:
        self.assertEqual(undocumented("fn f() {\n    let x = unsafe { g() };\n}\n"), [2])
        self.assertEqual(
            undocumented("fn f() {\n    // SAFETY: g has no preconditions.\n    let x = unsafe { g() };\n}\n"),
            [],
        )
        self.assertEqual(
            undocumented("    // SAFETY: live handle.\n    assert_eq!(\n        unsafe { g(h) },\n        0\n    );\n"),
            [],
        )
        self.assertEqual(undocumented("struct S;\nunsafe impl Send for S {}\n"), [2])
        self.assertEqual(undocumented('let s = "unsafe { not code }";\n'), [])


if __name__ == "__main__":
    unittest.main()
