from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError


SCRIPT = Path(__file__).resolve().parents[1] / "reconcile_registry_artifact.py"
SPEC = importlib.util.spec_from_file_location("reconcile_registry_artifact", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
reconcile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reconcile)


class RegistryArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.artifact = Path(self.temporary_directory.name) / "artifact.tgz"
        self.artifact.write_bytes(b"validated artifact")

    def response(self, payload: object) -> io.BytesIO:
        if isinstance(payload, bytes):
            return io.BytesIO(payload)
        return io.BytesIO(json.dumps(payload).encode())

    def test_crates_requires_the_exact_downloaded_bytes(self) -> None:
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(self.artifact.read_bytes())
        ):
            self.assertEqual(
                reconcile.registry_status(
                    "crates", "cmux-client", "1.0.0", self.artifact
                ),
                reconcile.MATCH,
            )

        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(b"different")
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_missing_registry_version_is_publishable(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        with mock.patch.object(reconcile, "urlopen", side_effect=missing):
            self.assertEqual(
                reconcile.registry_status(
                    "crates", "cmux-client", "1.0.0", self.artifact
                ),
                reconcile.MISSING,
            )

    def test_npm_uses_the_registry_integrity_digest(self) -> None:
        metadata = {
            "dist": {"integrity": reconcile._integrity(self.artifact, "sha512")}
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ):
            self.assertEqual(
                reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact),
                reconcile.MATCH,
            )

        metadata["dist"]["integrity"] = "sha512-invalid"
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_matches_the_exact_filename_and_sha256(self) -> None:
        metadata = {
            "urls": [
                {
                    "filename": self.artifact.name,
                    "digests": {
                        "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest()
                    },
                }
            ]
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ):
            self.assertEqual(
                reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact),
                reconcile.MATCH,
            )

        metadata["urls"][0]["filename"] = "other.whl"
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_rejects_unexpected_release_files(self) -> None:
        metadata = {
            "urls": [
                {
                    "filename": self.artifact.name,
                    "digests": {
                        "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest()
                    },
                },
                {
                    "filename": "cmux_sdk-1.0.0-cp313-cp313-manylinux.whl",
                    "digests": {"sha256": hashlib.sha256(b"unexpected").hexdigest()},
                },
            ]
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_rejects_yanked_release_files(self) -> None:
        metadata = {
            "urls": [
                {
                    "filename": self.artifact.name,
                    "digests": {
                        "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest()
                    },
                    "yanked": True,
                }
            ]
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_accepts_an_exact_allowed_sibling(self) -> None:
        sibling = Path(self.temporary_directory.name) / "cmux_sdk-1.0.0.tar.gz"
        sibling.write_bytes(b"validated source distribution")
        metadata = {
            "urls": [
                {
                    "filename": sibling.name,
                    "digests": {
                        "sha256": hashlib.sha256(sibling.read_bytes()).hexdigest()
                    },
                    "yanked": False,
                }
            ]
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ):
            self.assertEqual(
                reconcile.registry_status(
                    "pypi",
                    "cmux-sdk",
                    "1.0.0",
                    self.artifact,
                    (self.artifact, sibling),
                ),
                reconcile.MISSING,
            )

    def test_registry_wait_can_be_cancelled(self) -> None:
        cancelled = threading.Event()
        cancelled.set()
        with mock.patch.object(reconcile, "registry_status") as status:
            with self.assertRaises(reconcile.RegistryError):
                reconcile.wait_for_status(
                    "pypi",
                    "cmux-sdk",
                    "1.0.0",
                    self.artifact,
                    120,
                    cancel_event=cancelled,
                )
        status.assert_not_called()

    def test_registry_wait_honors_its_deadline_without_wall_clock_sleep(self) -> None:
        clock = [10.0]
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False

        def advance(timeout: float) -> bool:
            clock[0] += timeout
            return False

        cancellation.wait.side_effect = advance
        with mock.patch.object(
            reconcile.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(
            reconcile, "registry_status", return_value=reconcile.MISSING
        ) as status:
            self.assertEqual(
                reconcile.wait_for_status(
                    "pypi",
                    "cmux-sdk",
                    "1.0.0",
                    self.artifact,
                    6,
                    cancel_event=cancellation,
                ),
                reconcile.MISSING,
            )
        self.assertEqual(cancellation.wait.call_args_list, [mock.call(5), mock.call(1)])
        self.assertEqual(status.call_count, 3)

    def test_failed_publish_is_success_when_exact_bytes_appear(self) -> None:
        with mock.patch.object(
            reconcile,
            "registry_status",
            side_effect=(reconcile.MISSING, reconcile.MATCH),
        ), mock.patch.object(
            reconcile.subprocess,
            "run",
            return_value=types.SimpleNamespace(returncode=7),
        ):
            result = reconcile.main(
                [
                    "publish",
                    "--registry",
                    "npm",
                    "--package",
                    "cmux-sdk",
                    "--version",
                    "1.0.0",
                    "--artifact",
                    str(self.artifact),
                    "--wait-seconds",
                    "120",
                    "--",
                    "npm",
                    "publish",
                ]
            )
        self.assertEqual(result, 0)

    def test_exact_existing_artifact_skips_publish(self) -> None:
        with mock.patch.object(
            reconcile, "registry_status", return_value=reconcile.MATCH
        ), mock.patch.object(reconcile.subprocess, "run") as publish:
            result = reconcile.main(
                [
                    "publish",
                    "--registry",
                    "npm",
                    "--package",
                    "cmux-sdk",
                    "--version",
                    "1.0.0",
                    "--artifact",
                    str(self.artifact),
                    "--",
                    "npm",
                    "publish",
                ]
            )
        self.assertEqual(result, 0)
        publish.assert_not_called()

    def test_check_writes_match_or_missing_for_workflow_branching(self) -> None:
        output = Path(self.temporary_directory.name) / "github-output"
        with mock.patch.dict(
            os.environ, {"GITHUB_OUTPUT": str(output)}
        ), mock.patch.object(
            reconcile,
            "registry_status",
            return_value=reconcile.MISSING,
        ):
            result = reconcile.main(
                [
                    "check",
                    "--registry",
                    "pypi",
                    "--package",
                    "cmux-sdk",
                    "--version",
                    "1.0.0",
                    "--artifact",
                    str(self.artifact),
                    "--write-github-output",
                ]
            )
        self.assertEqual(result, 0)
        self.assertEqual(output.read_text(), "status=missing\n")


if __name__ == "__main__":
    unittest.main()
