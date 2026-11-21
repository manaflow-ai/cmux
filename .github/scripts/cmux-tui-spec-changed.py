#!/usr/bin/env python3
"""Whether a change touches one of cmux-tui-spec.yml's `push` paths: writes `run=true` or `run=false` to $GITHUB_OUTPUT.

feat-cmux-next requires `clippy (changed cmux-tui packages)` (2026-11-04: #35133 and #35149 merged with it red, as no
check was required). A required check must report on every pull request, so the workflow runs on each one, and its
`changes` job runs this: a change that touches none of the paths skips the other jobs, which GitHub counts as passing.
The `push` trigger's `paths:` list is the only list (tests/test_cargo_test_verdict.py keeps it whole); globs follow
GitHub's rules: `**` crosses folders, `*` does not. No base (a push, a dispatch) or a base the checkout lacks: run.

  cmux-tui-spec-changed.py --repo DIR --workflow .github/workflows/cmux-tui-spec.yml --base SHA --head SHA
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


def push_paths(workflow: str) -> list[str]:
    """The `paths:` globs of the workflow's `push` trigger, read without a YAML parser."""
    found, event, inside = [], None, False
    for line in workflow.splitlines():
        if match := re.match(r"^  ([a-z_]+):", line):
            event, inside = match.group(1), False
        elif re.match(r"^\S", line):
            event, inside = None, False
        elif event == "push" and re.match(r"^    paths:\s*$", line):
            inside = True
        elif inside and (match := re.match(r'^      - "([^"]+)"\s*$', line)):
            found.append(match.group(1))
        elif inside and not re.match(r"^\s*(#.*)?$", line):
            inside = False
    return found


def matches(glob: str, path: str) -> bool:
    pattern = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                      for part in re.split(r"(\*\*|\*)", glob))
    return re.fullmatch(pattern, path) is not None


def changed(repo: str, base: str, head: str) -> list[str] | None:
    """The paths base..head changes (a deletion or rename counts both sides); None when git cannot tell."""
    result = subprocess.run(["git", "-C", repo, "diff", "--no-renames", "--name-only", base, head],
                            capture_output=True, text=True, check=False)
    return None if result.returncode else [p for p in result.stdout.splitlines() if p]


def decide(repo: str, workflow: str, base: str, head: str) -> bool:
    globs = push_paths((Path(repo) / workflow).read_text())
    if not globs:
        sys.exit(f"cmux-tui-spec-changed: no push paths in {workflow}; refusing to skip the jobs")
    if not re.fullmatch(r"[0-9a-f]{40}", base or "") or set(base) == {"0"}:
        print("no pull request base: the jobs run")
        return True
    paths = changed(repo, base, head)
    if paths is None:
        print(f"cannot diff {base[:12]}..{head[:12]} here: the jobs run")
        return True
    hits = [p for p in paths if any(matches(g, p) for g in globs)]
    print(f"{len(paths)} changed path(s), {len(hits)} on the workflow's paths" + (f": {', '.join(hits[:5])}" if hits else ""))
    return bool(hits)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".")
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    a = parser.parse_args()
    run = decide(a.repo, a.workflow, a.base, a.head)
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write(f"run={'true' if run else 'false'}\n")


if __name__ == "__main__":
    main()
