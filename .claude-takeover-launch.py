#!/usr/bin/env python3
import subprocess
import pathlib

root = pathlib.Path(__file__).resolve().parent
prompt = (root / ".claude-takeover-prompt.txt").read_text()
subprocess.run(
    [
        "claude",
        "--dangerously-skip-permissions",
        "--model",
        "fable",
        "--effort",
        "medium",
        prompt,
    ],
    cwd=root,
)
