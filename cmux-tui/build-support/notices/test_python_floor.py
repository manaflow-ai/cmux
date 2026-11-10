#!/usr/bin/env python3
"""Under a python3 older than 3.11.4 (macOS's /usr/bin/python3 is 3.9.6) the
notices tools end with one line that names the needed version, both reasons
and the interpreter, and the generator says it before its first git or curl
call.

Nightly run 42775849251: an owned Mac had only that python3, and "Generate the
third-party notices" ended, after its downloads, in a traceback from
`import tomllib`. Python 3.11.0 to 3.11.3 has tomllib but not tarfile's
extraction filter (3.11.4), so fetch_crates.py ended there in a TypeError
after its first download.

No old python need be installed here: the tool runs in an interpreter that
reports the old version (and, for one older than 3.11, cannot import tomllib).
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
GENERATOR = ROOT / "scripts/cmux-next/generate-third-party-notices.sh"
# Every tool of this folder that reads TOML (rust_notices.py through cargo_inputs.py).
TOML_TOOLS = ("fetch_crates.py", "rust_notices.py", "review_list.py", "fetch_reviewed_text.py")

AS_OLD_PYTHON = """
import collections, runpy, sys
version = tuple(int(part) for part in sys.argv[1].split("."))
script = sys.argv[2]
sys.argv = sys.argv[2:]
sys.path[0] = __import__("os").path.dirname(script)  # what `python3 script` does
if version < (3, 11):
    sys.modules["tomllib"] = None  # import tomllib raises ImportError, as on 3.9
sys.version_info = collections.namedtuple("version_info", "major minor micro releaselevel serial")(*version, "final", 0)
runpy.run_path(script, run_name="__main__")
"""
# macOS's python3; the last 3.10; the last 3.11 without tarfile's extraction filter.
OLD_VERSIONS = ("3.9.6", "3.10.14", "3.11.3")


def run_as_old_python(version: str, tool: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-c", AS_OLD_PYTHON, version, str(HERE / tool), "--help"],
                          capture_output=True, text=True)


class OldPython(unittest.TestCase):
    def test_each_toml_tool_ends_with_one_line_that_names_the_floor_both_reasons_and_the_interpreter(self):
        for version in OLD_VERSIONS:
            for tool in TOML_TOOLS:
                with self.subTest(version=version, tool=tool):
                    result = run_as_old_python(version, tool)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertNotIn("Traceback", result.stderr)
                    lines = result.stderr.splitlines()
                    self.assertEqual(len(lines), 1, result.stderr)
                    self.assertIn("Python 3.11.4 or newer", lines[0])
                    self.assertIn("tomllib", lines[0])
                    self.assertIn("tarfile", lines[0])
                    self.assertIn("Python " + version, lines[0])
                    self.assertIn(sys.executable, lines[0])

    @unittest.skipIf(sys.version_info < (3, 11, 4), "this python3 is older than the floor")
    def test_this_python_runs_the_tools(self):
        for tool in TOML_TOOLS:
            with self.subTest(tool=tool):
                result = subprocess.run([sys.executable, str(HERE / tool), "--help"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")


class Generator(unittest.TestCase):
    """The generator with a python3, a git and a curl that write each call to one
    list, in order. git and curl always fail, so the run stops at its first use
    of either."""

    def run_generator(self, python3: str) -> tuple[subprocess.CompletedProcess, list[str], Path]:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        calls = root / "calls"
        (root / "bin").mkdir()
        fakes = {"python3": python3, "git": 'echo "git says no" >&2\nexit 1', "curl": 'echo "curl says no" >&2\nexit 1'}
        for name, body in fakes.items():
            fake = root / "bin" / name
            fake.write_text(f'#!/bin/sh\necho "{name} $1" >> "{calls}"\n{body}\n')
            fake.chmod(0o755)
        env = {**os.environ, "PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}",
               "CMUX_NOTICES_CACHE": str(root / "cache")}
        result = subprocess.run([str(GENERATOR), "--tui-source", "tree"], env=env, capture_output=True, text=True)
        return result, calls.read_text().splitlines(), root / "cache"

    def test_an_old_python_stops_the_generator_before_its_first_git_or_curl_call(self):
        """python3 fails every call, as the floor does under an old python3: the
        floor check is the only call, so no git, curl or other python3 ran before it."""
        result, calls, cache = self.run_generator('echo "floor says no" >&2\nexit 1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [f"python3 {HERE / 'python_floor.py'}"])
        self.assertEqual(result.stderr, "floor says no\n")
        self.assertFalse(cache.exists())

    @unittest.skipIf(sys.version_info < (3, 11, 4), "this python3 is older than the floor")
    def test_the_floor_check_runs_before_the_first_git_or_curl_call(self):
        """python3 is this interpreter, so the floor passes and the run goes on to
        its first git call, which the list must show after the floor check. This
        also proves that the list sees the generator's git calls."""
        result, calls, _ = self.run_generator(f'exec "{sys.executable}" "$@"')
        self.assertNotEqual(result.returncode, 0)
        network = [index for index, call in enumerate(calls) if call.split()[0] in ("git", "curl")]
        self.assertTrue(network, calls)
        self.assertLess(calls.index(f"python3 {HERE / 'python_floor.py'}"), network[0])
        self.assertIn("git says no", result.stderr)


if __name__ == "__main__":
    unittest.main()
