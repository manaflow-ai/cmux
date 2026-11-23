#!/usr/bin/env python3
"""Behavior test: the pinned-toolchain step reinstalls a toolchain that cannot run.

Runs the step's own Python (read out of action.yml) against a fake rustup whose
toolchain is half-written, as on cmux-runner-pool-c1c-0011 (jobs 137263606985,
137336474322): install says "unchanged" and rustdoc is missing.
"""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ACTION = Path(__file__).resolve().parents[1] / "action.yml"

FAKE_RUSTUP = r'''#!PYTHON
import pathlib, sys
state = pathlib.Path(__file__).parent / "state"
bin_dir = pathlib.Path(__file__).parent / "toolchain-bin"
with open(state / "log", "a") as log:
    print(" ".join(sys.argv[1:]), file=log)
args = sys.argv[1:]
healthy = (state / "installed").exists() and not (state / "broken").exists()
if args[:2] == ["toolchain", "install"]:
    if (state / "installed").exists():
        print("1.95.0-x86_64-unknown-linux-gnu unchanged - (error reading rustc version)")
    (state / "installed").touch()
    sys.exit(0)
if args[:2] == ["toolchain", "uninstall"]:
    if (state / "uninstall-fails").exists():
        sys.exit(1)
    for name in ("installed", "broken"):
        (state / name).unlink(missing_ok=True)
    sys.exit(0)
if args[0] == "which":
    if not healthy:
        sys.exit(1)
    print(bin_dir / args[-1])
    sys.exit(0)
if args[0] == "run":
    if not healthy:
        sys.exit(1)
    print(f"{args[2]} 1.95.0")
    sys.exit(0)
if args[0] == "default":
    sys.exit(0)
sys.exit(2)
'''


def step_python() -> str:
    text = ACTION.read_text(encoding="utf-8")
    start = text.index("\"$python_cmd\" <<'PY'\n") + len("\"$python_cmd\" <<'PY'\n")
    end = text.index("\n        PY\n", start)
    return "\n".join(line[8:] for line in text[start:end].splitlines()) + "\n"


class ToolchainSelfHealTests(unittest.TestCase):
    def run_step(self, root: Path, *, broken: bool, uninstall_fails: bool = False):
        state = root / "state"
        state.mkdir()
        bin_dir = root / "toolchain-bin"
        bin_dir.mkdir()
        for tool in ("rustc", "cargo", "rustdoc"):
            tool_file = bin_dir / tool
            tool_file.write_text("#!/bin/sh\necho \"$0 1.95.0\"\n")
            tool_file.chmod(0o755)
        rustup = root / "rustup"
        rustup.write_text(FAKE_RUSTUP.replace("PYTHON", sys.executable, 1))
        rustup.chmod(0o755)
        rustup_home = root / "rustup-home"
        (rustup_home / "toolchains" / "1.95.0-x86_64-unknown-linux-gnu").mkdir(parents=True)
        (rustup_home / "update-hashes").mkdir()
        (rustup_home / "update-hashes" / "1.95.0-x86_64-unknown-linux-gnu").write_text("x")
        if broken:
            (state / "installed").touch()
            (state / "broken").touch()
        if uninstall_fails:
            (state / "uninstall-fails").touch()
        toolchain_file = root / "rust-toolchain.toml"
        toolchain_file.write_text(
            '[toolchain]\nchannel = "1.95.0"\nprofile = "minimal"\n'
            'components = ["clippy", "rustfmt"]\n'
        )
        github_path = root / "github_path"
        github_env = root / "github_env"
        github_path.touch()
        github_env.touch()
        result = subprocess.run(
            [sys.executable, "-I", "-c", step_python()],
            env={
                **os.environ,
                "PATH": f"{root}:/bin:/usr/bin",
                "RUSTUP_HOME": str(rustup_home),
                "TOOLCHAIN_FILE": str(toolchain_file),
                "GITHUB_PATH": str(github_path),
                "GITHUB_ENV": str(github_env),
            },
            capture_output=True,
            text=True,
        )
        log = (state / "log").read_text().splitlines()
        return result, log, github_env.read_text(), rustup_home

    def test_healthy_toolchain_installs_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result, log, env, rustup_home = self.run_step(Path(directory), broken=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("toolchain uninstall 1.95.0", log)
            installs = [line for line in log if line.startswith("toolchain install")]
            self.assertEqual(
                installs,
                ["toolchain install 1.95.0 --profile minimal --component clippy --component rustfmt"],
            )
            self.assertIn("CMUX_TUI_RUSTDOC=", env)
            self.assertTrue((rustup_home / "cmux-toolchain.lock").exists())

    def test_broken_toolchain_is_uninstalled_and_reinstalled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result, log, env, _ = self.run_step(Path(directory), broken=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("reinstalling it", result.stdout)
            uninstall = log.index("toolchain uninstall 1.95.0")
            reinstall = [i for i, line in enumerate(log) if line.startswith("toolchain install")]
            self.assertEqual(len(reinstall), 2)
            self.assertLess(reinstall[0], uninstall)
            self.assertLess(uninstall, reinstall[1])
            self.assertIn("rustdoc", env)

    def test_unreadable_toolchain_files_are_dropped_before_reinstall(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result, _, _, rustup_home = self.run_step(
                Path(directory), broken=True, uninstall_fails=True
            )
            # The fake's uninstall fails and leaves its marker, so the repair still fails,
            # but the step dropped the toolchain's files and says so.
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("still broken after a reinstall", result.stderr)
            self.assertEqual(list((rustup_home / "toolchains").iterdir()), [])
            self.assertEqual(list((rustup_home / "update-hashes").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
