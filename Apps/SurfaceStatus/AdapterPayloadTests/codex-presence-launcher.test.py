#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

LAUNCHER = pathlib.Path(__file__).parents[1] / "SurfaceStatusApp/AdapterPayloads/codex-presence-launcher.py"


class CodexPresenceLauncherTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="surface-status-codex-launcher-"))
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.output = self.root / "invocation.json"

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def executable(self, name: str, body: str) -> pathlib.Path:
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def environment(self, **extra: str) -> dict[str, str]:
        environment = {
            "HOME": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "CMUX_SURFACE_ID": str(uuid.uuid4()),
            "CMUX_WORKSPACE_ID": str(uuid.uuid4()),
            "OUTPUT": str(self.output),
        }
        environment.update(extra)
        return environment

    def marker_files(self) -> list[pathlib.Path]:
        directory = self.home / ".cmuxterm"
        return list(directory.glob("codex-*-sidebar-agent-launch.json")) if directory.exists() else []

    def test_prefers_official_cmux_wrapper_shim_and_preserves_argv(self):
        shim = self.executable(
            "official-codex-shim",
            f"{sys.executable!s} -c 'import json, os, sys; json.dump({{\"argv\": sys.argv[1:]}}, open(os.environ[\"OUTPUT\"], \"w\"))' -- \"$@\"\n",
        )
        self.executable("codex", "exit 91\n")
        result = subprocess.run(
            [sys.executable, str(LAUNCHER), "--model", "test model", "--flag=value"],
            env=self.environment(CMUX_CODEX_WRAPPER_SHIM=str(shim)),
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        invocation = json.loads(self.output.read_text())
        self.assertEqual(invocation["argv"][1:], ["--model", "test model", "--flag=value"])
        self.assertEqual(len(self.marker_files()), 1)

    def test_optout_is_preserved_and_suppresses_marker(self):
        shim = self.executable(
            "official-codex-shim",
            "printf '%s' \"${CMUX_CODEX_HOOKS_DISABLED-unset}\" > \"$OUTPUT\"\n",
        )
        result = subprocess.run(
            [sys.executable, str(LAUNCHER)],
            env=self.environment(CMUX_CODEX_WRAPPER_SHIM=str(shim), CMUX_CODEX_HOOKS_DISABLED="1"),
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), "1")
        self.assertEqual(self.marker_files(), [])

    def test_deleted_working_directory_cannot_block_downstream_launch(self):
        downstream = self.executable("codex", "printf launched > \"$OUTPUT\"\n")
        cwd = self.root / "deleted-cwd"
        cwd.mkdir()
        ready_read, ready_write = os.pipe()
        go_read, go_write = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(ready_read)
                os.close(go_write)
                os.chdir(cwd)
                os.write(ready_write, b"1")
                os.read(go_read, 1)
                os.execve(
                    sys.executable,
                    [sys.executable, str(LAUNCHER), "--version"],
                    self.environment(CMUX_SURFACE_STATUS_CODEX_REAL=str(downstream)),
                )
            finally:
                os._exit(126)
        os.close(ready_write)
        os.close(go_read)
        self.assertEqual(os.read(ready_read, 1), b"1")
        cwd.rmdir()
        os.write(go_write, b"1")
        _, status = os.waitpid(pid, 0)
        self.assertTrue(os.WIFEXITED(status))
        self.assertEqual(os.WEXITSTATUS(status), 0)
        self.assertEqual(self.output.read_text(), "launched")


if __name__ == "__main__":
    unittest.main()
