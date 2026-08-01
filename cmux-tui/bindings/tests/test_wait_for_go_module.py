from __future__ import annotations

import importlib.util
import json
import subprocess
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
        runner = mock.Mock(
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
            runner=runner,
            cancel_event=cancellation,
        )

        self.assertEqual(metadata["Path"], self.module)
        self.assertEqual(metadata["Version"], self.version)
        self.assertEqual(runner.call_count, 2)
        cancellation.wait.assert_called_once()

    def test_retry_deadline_is_bounded_without_wall_clock_sleep(self) -> None:
        runner = mock.Mock(return_value=self.result(1, "proxy unavailable"))
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        clock = [10.0]

        def advance(timeout: float) -> bool:
            clock[0] += timeout
            return False

        cancellation.wait.side_effect = advance
        with self.assertRaisesRegex(waiter.GoModuleUnavailable, "proxy unavailable"):
            waiter.wait_for_module(
                self.module,
                self.version,
                wait_seconds=45,
                retry_seconds=30,
                runner=runner,
                clock=lambda: clock[0],
                cancel_event=cancellation,
            )

        self.assertEqual(
            cancellation.wait.call_args_list,
            [mock.call(30), mock.call(15)],
        )
        self.assertEqual(runner.call_count, 3)

    def test_success_metadata_must_match_the_requested_module(self) -> None:
        runner = mock.Mock(
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
                runner=runner,
            )


if __name__ == "__main__":
    unittest.main()
