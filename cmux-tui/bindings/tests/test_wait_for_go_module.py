from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "wait_for_go_module.py"
SPEC = importlib.util.spec_from_file_location("wait_for_go_module", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
waiter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(waiter)


class WaitForGoModuleTests(unittest.TestCase):
    module = "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
    version = "v1.0.0"

    def result(self, returncode: int, payload: object) -> subprocess.CompletedProcess[str]:
        stdout = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.CompletedProcess(
            ["go", "mod", "download"],
            returncode,
            stdout=stdout,
            stderr="",
        )

    def test_retries_unavailable_version_then_accepts_exact_module(self) -> None:
        executor = mock.Mock(
            side_effect=(
                self.result(1, {"Error": "not found"}),
                self.result(
                    0,
                    {"Path": self.module, "Version": self.version},
                ),
            )
        )
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        cancellation.wait.return_value = False

        metadata = waiter.wait_for_module(
            self.module,
            self.version,
            wait_seconds=1800,
            retry_seconds=30,
            executor=executor,
            cancel_event=cancellation,
        )

        self.assertEqual(metadata["Path"], self.module)
        self.assertEqual(metadata["Version"], self.version)
        self.assertEqual(executor.call_count, 2)
        cancellation.wait.assert_called_once()

    def test_retry_deadline_is_bounded_without_wall_clock_sleep(self) -> None:
        executor = mock.Mock(return_value=self.result(1, "proxy unavailable"))
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        clock = [10.0]

        def advance(timeout: float) -> bool:
            clock[0] += timeout
            return False

        cancellation.wait.side_effect = advance
        with self.assertRaisesRegex(
            waiter.GoModuleUnavailable,
            "public proxy or checksum database",
        ):
            waiter.wait_for_module(
                self.module,
                self.version,
                wait_seconds=45,
                retry_seconds=30,
                executor=executor,
                clock=lambda: clock[0],
                cancel_event=cancellation,
            )

        self.assertEqual(
            cancellation.wait.call_args_list,
            [mock.call(30), mock.call(15)],
        )
        self.assertEqual(executor.call_count, 3)

    def test_success_metadata_must_match_the_requested_module(self) -> None:
        executor = mock.Mock(
            return_value=self.result(
                0,
                {"Path": "example.com/wrong", "Version": self.version},
            )
        )
        with self.assertRaisesRegex(waiter.GoModuleError, "unexpected module"):
            waiter.wait_for_module(
                self.module,
                self.version,
                wait_seconds=0,
                retry_seconds=30,
                executor=executor,
            )

    def test_forces_a_fresh_public_environment(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        inherited_cache = Path(temporary_directory.name) / "ambient-cache"
        inherited_cache.mkdir()
        (inherited_cache / "cached-module").write_text("stale")
        observed: dict[str, str] = {}

        def execute(*_args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
            environment = kwargs["env"]
            observed.update(environment)
            cache = Path(environment["GOMODCACHE"])
            self.assertTrue(cache.is_dir())
            self.assertEqual(list(cache.iterdir()), [])
            return self.result(
                0,
                {"Path": self.module, "Version": self.version},
            )

        with mock.patch.dict(
            os.environ,
            {
                "GOENV": "/tmp/private-go-env",
                "GOPROXY": "off",
                "GOPRIVATE": "github.com/manaflow-ai/*",
                "GONOPROXY": "github.com/manaflow-ai/*",
                "GONOSUMDB": "github.com/manaflow-ai/*",
                "GOMODCACHE": str(inherited_cache),
            },
        ):
            waiter.wait_for_module(
                self.module,
                self.version,
                wait_seconds=30,
                retry_seconds=5,
                executor=execute,
            )

        self.assertEqual(observed["GOENV"], "off")
        self.assertEqual(observed["GOPROXY"], "https://proxy.golang.org")
        self.assertEqual(observed["GOSUMDB"], "sum.golang.org")
        self.assertEqual(observed["GOPRIVATE"], "")
        self.assertEqual(observed["GONOPROXY"], "none")
        self.assertEqual(observed["GONOSUMDB"], "none")
        self.assertNotEqual(observed["GOMODCACHE"], str(inherited_cache))

    def test_upstream_diagnostics_are_not_exposed(self) -> None:
        secret = "https://token@example.invalid/private"
        executor = mock.Mock(
            return_value=subprocess.CompletedProcess(
                ["go", "mod", "download"],
                1,
                stdout=json.dumps({"Error": secret}),
                stderr=f"proxy failed: {secret}",
            )
        )
        with self.assertRaises(waiter.GoModuleUnavailable) as failure:
            waiter.wait_for_module(
                self.module,
                self.version,
                wait_seconds=0,
                retry_seconds=5,
                executor=executor,
            )
        self.assertNotIn(secret, str(failure.exception))

    def test_running_download_is_cancelled_and_terminated(self) -> None:
        process = mock.Mock()
        process.args = ["go", "mod", "download"]
        process.returncode = -15
        process.wait.return_value = -15
        cancellation = mock.Mock()
        cancellation.is_set.side_effect = (False, True)
        with mock.patch.object(waiter.subprocess, "Popen", return_value=process), \
            self.assertRaises(waiter.GoModuleCancellation):
            waiter._run_command(
                process.args,
                env={},
                deadline=30.0,
                clock=lambda: 0.0,
                cancel_event=cancellation,
            )
        process.terminate.assert_called_once()

    def test_running_download_is_terminated_at_the_deadline(self) -> None:
        process = mock.Mock()
        process.args = ["go", "mod", "download"]
        process.returncode = -15
        process.wait.return_value = -15
        clock = mock.Mock(side_effect=(0.0, 31.0))
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        with mock.patch.object(waiter.subprocess, "Popen", return_value=process), \
            self.assertRaises(waiter.GoModuleAttemptTimeout):
            waiter._run_command(
                process.args,
                env={},
                deadline=30.0,
                clock=clock,
                cancel_event=cancellation,
            )
        process.terminate.assert_called_once()

    def test_running_download_polls_exit_without_reusing_communicate(self) -> None:
        process = mock.Mock()
        process.args = ["go", "mod", "download"]
        process.returncode = 0
        process.wait.side_effect = (
            subprocess.TimeoutExpired(process.args, 0.25),
            0,
        )
        process.communicate.side_effect = (
            subprocess.TimeoutExpired(process.args, 0.25),
            ("", ""),
        )
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        with mock.patch.object(waiter.subprocess, "Popen", return_value=process):
            waiter._run_command(
                process.args,
                env={},
                deadline=30.0,
                clock=lambda: 0.0,
                cancel_event=cancellation,
            )
        self.assertEqual(process.wait.call_count, 2)
        process.communicate.assert_not_called()

    def test_non_utf8_tool_output_is_decoded_safely(self) -> None:
        result = waiter._run_command(
            [sys.executable, "-c", "import os; os.write(1, b'\\xff')"],
            env=os.environ.copy(),
            deadline=30.0,
            clock=lambda: 0.0,
            cancel_event=waiter.threading.Event(),
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "\ufffd")

    def test_main_reports_cancellation_with_the_signal_exit_code(self) -> None:
        cancellation = waiter.threading.Event()
        with mock.patch.object(
            waiter,
            "wait_for_module",
            side_effect=waiter.GoModuleCancellation("cancelled"),
        ) as wait_for_module:
            result = waiter.main(
                [
                    "--module",
                    self.module,
                    "--version",
                    self.version,
                    "--wait-seconds",
                    "30",
                ],
                cancel_event=cancellation,
            )

        self.assertEqual(result, 130)
        self.assertIs(
            wait_for_module.call_args.kwargs["cancel_event"],
            cancellation,
        )

    def test_cli_signals_set_cancellation_and_restore_handlers(self) -> None:
        handlers: dict[int, object] = {}
        previous = {
            signal.SIGINT: object(),
            signal.SIGTERM: object(),
        }
        restored: dict[int, object] = {}

        def install(signum: int, handler: object) -> object:
            if signum not in handlers:
                handlers[signum] = handler
                return previous[signum]
            restored[signum] = handler
            return handlers[signum]

        def main(*, cancel_event: waiter.threading.Event) -> int:
            handler = handlers[signal.SIGTERM]
            assert callable(handler)
            handler(signal.SIGTERM, None)
            self.assertTrue(cancel_event.is_set())
            return 130

        with mock.patch.object(
            waiter.signal,
            "signal",
            side_effect=install,
        ), mock.patch.object(waiter, "main", side_effect=main):
            self.assertEqual(waiter._run_cli(), 130)

        self.assertEqual(restored, previous)


if __name__ == "__main__":
    unittest.main()
