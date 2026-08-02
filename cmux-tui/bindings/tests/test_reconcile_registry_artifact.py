from __future__ import annotations

import hashlib
import http.client
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
from urllib.error import HTTPError, URLError


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
        def crates_response(archive: bytes):
            def response(request: object, **_kwargs: object) -> io.BytesIO:
                url = str(getattr(request, "full_url", ""))
                if url.endswith("/download"):
                    return self.response(archive)
                if url.endswith("/1.0.0"):
                    return self.response({"version": {"yanked": False}})
                return self.response({
                    "crate": {"name": "cmux-client"},
                    "versions": [{"num": "1.0.0", "yanked": False}],
                })

            return response

        with mock.patch.object(
            reconcile,
            "urlopen",
            side_effect=crates_response(self.artifact.read_bytes()),
        ):
            self.assertEqual(
                reconcile.registry_status(
                    "crates", "cmux-client", "1.0.0", self.artifact
                ),
                reconcile.MATCH,
            )

        with mock.patch.object(
            reconcile,
            "urlopen",
            side_effect=crates_response(b"different"),
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_crates_rejects_exact_old_bytes_behind_registry_history(self) -> None:
        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            if url.endswith("/download"):
                return self.response(self.artifact.read_bytes())
            if url.endswith("/1.0.0"):
                return self.response({"version": {"yanked": False}})
            return self.response({
                "crate": {"name": "cmux-client"},
                "versions": [
                    {"num": "1.0.0", "yanked": False},
                    {"num": "1.1.0", "yanked": False},
                ],
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_crates_rejects_a_yanked_exact_archive(self) -> None:
        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/download"):
                return self.response(self.artifact.read_bytes())
            return self.response({"version": {"yanked": True}})

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.RegistryError):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_missing_crates_version_is_publishable_when_project_exists(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0"):
                raise missing
            return self.response({
                "crate": {"name": "cmux-client"},
                "versions": [{"num": "0.1.2", "yanked": False}],
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status(
                    "crates", "cmux-client", "1.0.0", self.artifact
                ),
                reconcile.MISSING,
            )

    def test_crates_rejects_a_missing_version_behind_registry_history(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0"):
                raise missing
            return self.response({
                "crate": {"name": "cmux-client"},
                "versions": [{"num": "1.1.0", "yanked": False}],
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_crates_retries_when_history_precedes_the_version_endpoint(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0"):
                raise missing
            return self.response({
                "crate": {"name": "cmux-client"},
                "versions": [{"num": "1.0.0", "yanked": False}],
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.RegistryLookupError):
            reconcile.registry_status(
                "crates", "cmux-client", "1.0.0", self.artifact
            )

    def test_crates_allows_stable_after_its_prerelease(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0"):
                raise missing
            return self.response({
                "crate": {"name": "cmux-client"},
                "versions": [{"num": "1.0.0-rc.1", "yanked": False}],
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status(
                    "crates", "cmux-client", "1.0.0", self.artifact
                ),
                reconcile.MISSING,
            )

    def test_crates_rejects_a_missing_project(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        with mock.patch.object(reconcile, "urlopen", side_effect=missing), \
            self.assertRaisesRegex(reconcile.RegistryError, "project"):
            reconcile.registry_status(
                "crates", "cmux-sidebar", "1.0.0", self.artifact
            )

    def test_crates_bootstrap_can_create_only_the_reserved_prerelease(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        with mock.patch.object(reconcile, "urlopen", side_effect=missing), \
            mock.patch.object(
                reconcile.subprocess,
                "run",
                return_value=mock.Mock(returncode=1),
            ):
            self.assertEqual(
                reconcile.main([
                    "publish",
                    "--registry", "crates",
                    "--package", "cmux-sidebar",
                    "--version", "0.0.0-bootstrap.0",
                    "--artifact", str(self.artifact),
                    "--allow-missing-project",
                    "--",
                    "false",
                ]),
                1,
            )

        with self.assertRaisesRegex(SystemExit, "bootstrap prerelease"):
            reconcile.main([
                "publish",
                "--registry", "crates",
                "--package", "cmux-sidebar",
                "--version", "1.0.0",
                "--artifact", str(self.artifact),
                "--allow-missing-project",
                "--",
                "false",
            ])

    def test_npm_uses_the_registry_integrity_digest(self) -> None:
        metadata = {
            "dist-tags": {"latest": "1.0.0"},
            "versions": {
                "1.0.0": {
                    "dist": {
                        "integrity": reconcile._integrity(self.artifact, "sha512")
                    }
                }
            },
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ):
            self.assertEqual(
                reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact),
                reconcile.MATCH,
            )

        metadata["versions"]["1.0.0"]["dist"]["integrity"] = "sha512-invalid"
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_npm_rejects_exact_old_bytes_behind_registry_history(self) -> None:
        dist = {"integrity": reconcile._integrity(self.artifact, "sha512")}
        metadata = {
            "dist-tags": {"latest": "1.0.0"},
            "versions": {
                "1.0.0": {"dist": dist},
                "1.1.0-beta.1": {"dist": {}},
            },
        }
        with mock.patch.object(
            reconcile,
            "urlopen",
            return_value=self.response(metadata),
        ), self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_npm_rejects_a_missing_project(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        with mock.patch.object(reconcile, "urlopen", side_effect=missing), \
            self.assertRaisesRegex(reconcile.RegistryError, "project"):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_npm_rejects_exact_bytes_when_latest_points_elsewhere(self) -> None:
        dist = {"integrity": reconcile._integrity(self.artifact, "sha512")}
        metadata = {
            "dist": dist,
            "dist-tags": {"latest": "0.9.0"},
            "versions": {"1.0.0": {"dist": dist}},
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.RegistryError):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_npm_rejects_a_missing_version_older_than_registry_history(self) -> None:
        metadata = {
            "dist-tags": {"latest": "2.0.0"},
            "versions": {"2.0.0": {"dist": {}}},
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ), self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact)

    def test_npm_allows_a_missing_version_newer_than_registry_history(self) -> None:
        metadata = {
            "dist-tags": {"latest": "0.9.0"},
            "versions": {"0.9.0": {"dist": {}}},
        }
        with mock.patch.object(
            reconcile, "urlopen", return_value=self.response(metadata)
        ):
            self.assertEqual(
                reconcile.registry_status("npm", "cmux-sdk", "1.0.0", self.artifact),
                reconcile.MISSING,
            )

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
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {"1.0.0": [{"yanked": False}]},
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(metadata if url.endswith("/1.0.0/json") else project)

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact),
                reconcile.MATCH,
            )

        metadata["urls"][0]["filename"] = "other.whl"
        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ArtifactMismatch):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_rejects_exact_old_bytes_behind_registry_history(self) -> None:
        exact = {
            "urls": [{
                "filename": self.artifact.name,
                "digests": {
                    "sha256": hashlib.sha256(
                        self.artifact.read_bytes()
                    ).hexdigest()
                },
                "yanked": False,
            }]
        }
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {
                "1.0.0": [{"yanked": False}],
                "1.1.0": [{"yanked": False}],
            },
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(exact if url.endswith("/1.0.0/json") else project)

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_accepts_the_attested_bootstrap_prerelease(self) -> None:
        metadata = {
            "urls": [{
                "filename": self.artifact.name,
                "digests": {
                    "sha256": hashlib.sha256(
                        self.artifact.read_bytes()
                    ).hexdigest()
                },
                "yanked": False,
            }],
        }
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {
                "0.0.0a0": [{"yanked": False}],
            },
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(
                metadata if url.endswith("/0.0.0a0/json") else project
            )

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status(
                    "pypi", "cmux-sdk", "0.0.0a0", self.artifact
                ),
                reconcile.MATCH,
            )

    def test_pypi_bootstrap_rejects_newer_prerelease_history(self) -> None:
        metadata = {
            "urls": [{
                "filename": self.artifact.name,
                "digests": {
                    "sha256": hashlib.sha256(
                        self.artifact.read_bytes()
                    ).hexdigest()
                },
                "yanked": False,
            }],
        }
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {
                "0.0.0a0": [{"yanked": False}],
                "0.0.0b0": [{"yanked": False}],
            },
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(
                metadata if url.endswith("/0.0.0a0/json") else project
            )

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status(
                "pypi", "cmux-sdk", "0.0.0a0", self.artifact
            )

    def test_pypi_retries_when_history_precedes_version_metadata(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {"1.0.0": [{"yanked": False}]},
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0/json"):
                raise missing
            return self.response(project)

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.RegistryLookupError):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_rejects_a_missing_project(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)
        with mock.patch.object(reconcile, "urlopen", side_effect=missing), \
            self.assertRaisesRegex(reconcile.RegistryError, "project"):
            reconcile.registry_status("pypi", "cmux-sdk", "1.0.0", self.artifact)

    def test_pypi_allows_a_missing_version_newer_than_registry_history(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0/json"):
                raise missing
            return self.response({
                "info": {"name": "cmux-sdk"},
                "releases": {
                    "0.0.0a0": [{"yanked": False}],
                    "0.9.0": [{"yanked": False}],
                },
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status(
                    "pypi", "cmux-sdk", "1.0.0", self.artifact
                ),
                reconcile.MISSING,
            )

    def test_pypi_rejects_a_missing_version_behind_registry_history(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0/json"):
                raise missing
            return self.response({
                "info": {"name": "cmux-sdk"},
                "releases": {"1.1.0": [{"yanked": False}]},
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status(
                "pypi", "cmux-sdk", "1.0.0", self.artifact
            )

    def test_pypi_allows_stable_after_its_prerelease(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0/json"):
                raise missing
            return self.response({
                "info": {"name": "cmux-sdk"},
                "releases": {"1.0.0rc1": [{"yanked": False}]},
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
            self.assertEqual(
                reconcile.registry_status(
                    "pypi", "cmux-sdk", "1.0.0", self.artifact
                ),
                reconcile.MISSING,
            )

    def test_pypi_rejects_a_postrelease_of_the_candidate(self) -> None:
        missing = HTTPError("https://registry.example", 404, "missing", None, None)

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            if str(getattr(request, "full_url", "")).endswith("/1.0.0/json"):
                raise missing
            return self.response({
                "info": {"name": "cmux-sdk"},
                "releases": {"1.0.0.post1": [{"yanked": False}]},
            })

        with mock.patch.object(reconcile, "urlopen", side_effect=response), \
            self.assertRaises(reconcile.ReleaseStateMismatch):
            reconcile.registry_status(
                "pypi", "cmux-sdk", "1.0.0", self.artifact
            )

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
        project = {
            "info": {"name": "cmux-sdk"},
            "releases": {"1.0.0": [{"yanked": False}]},
        }

        def response(request: object, **_kwargs: object) -> io.BytesIO:
            url = str(getattr(request, "full_url", ""))
            return self.response(metadata if url.endswith("/1.0.0/json") else project)

        with mock.patch.object(reconcile, "urlopen", side_effect=response):
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

    def test_registry_wait_retries_response_body_transport_failures(self) -> None:
        metadata = {
            "dist-tags": {"latest": "1.0.0"},
            "versions": {
                "1.0.0": {
                    "dist": {
                        "integrity": reconcile._integrity(self.artifact, "sha512")
                    }
                }
            },
        }
        failures = (
            TimeoutError("timed out"),
            ConnectionResetError("connection reset"),
            http.client.IncompleteRead(b"partial", 100),
        )
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                broken_response = mock.MagicMock()
                broken_response.__enter__.return_value.read.side_effect = failure
                cancellation = mock.Mock()
                cancellation.is_set.return_value = False
                clock = [10.0]

                def advance(timeout: float) -> bool:
                    clock[0] += timeout
                    return False

                cancellation.wait.side_effect = advance
                with mock.patch.object(
                    reconcile,
                    "urlopen",
                    side_effect=(broken_response, self.response(metadata)),
                ), mock.patch.object(
                    reconcile.time, "monotonic", side_effect=lambda: clock[0]
                ):
                    self.assertEqual(
                        reconcile.wait_for_status(
                            "npm",
                            "cmux-sdk",
                            "1.0.0",
                            self.artifact,
                            1,
                            cancel_event=cancellation,
                        ),
                        reconcile.MATCH,
                    )
                cancellation.wait.assert_called_once()

    def test_registry_lookup_errors_do_not_expose_upstream_details(self) -> None:
        registry_url = "https://private-proxy.internal/package"
        upstream_detail = "private-proxy.internal: token rejected"
        failures = (
            URLError(upstream_detail),
            ConnectionResetError(upstream_detail),
        )
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), mock.patch.object(
                reconcile,
                "urlopen",
                side_effect=failure,
            ), self.assertRaises(reconcile.RegistryLookupError) as raised:
                reconcile._request(registry_url, "application/json")
            message = str(raised.exception)
            self.assertNotIn(registry_url, message)
            self.assertNotIn(upstream_detail, message)

        http_failure = HTTPError(registry_url, 503, upstream_detail, None, None)
        with mock.patch.object(
            reconcile,
            "urlopen",
            side_effect=http_failure,
        ), self.assertRaises(reconcile.RegistryLookupError) as raised:
            reconcile._request(registry_url, "application/json")
        self.assertEqual(
            str(raised.exception),
            "registry request failed with HTTP 503",
        )

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

    def test_successful_publish_fails_without_postwrite_registry_match(self) -> None:
        with mock.patch.object(
            reconcile,
            "wait_for_status",
            side_effect=(reconcile.MISSING, reconcile.MISSING),
        ) as status, mock.patch.object(
            reconcile.subprocess,
            "run",
            return_value=types.SimpleNamespace(returncode=0),
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
        self.assertEqual(result, 1)
        self.assertEqual(status.call_count, 2)

    def test_publish_preflight_retries_lookup_errors_then_publishes_missing(self) -> None:
        cancellation = mock.Mock()
        cancellation.is_set.return_value = False
        cancellation.wait.return_value = False
        with mock.patch.object(
            reconcile,
            "registry_status",
            side_effect=(
                reconcile.RegistryLookupError("temporary registry failure"),
                reconcile.MISSING,
                reconcile.MATCH,
            ),
        ) as status, mock.patch.object(
            reconcile.subprocess,
            "run",
            return_value=types.SimpleNamespace(returncode=0),
        ) as publish:
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
                ],
                cancel_event=cancellation,
            )
        self.assertEqual(result, 0)
        self.assertEqual(status.call_count, 3)
        cancellation.wait.assert_called_once()
        publish.assert_called_once()

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

    def test_check_can_name_multiple_workflow_outputs(self) -> None:
        output = Path(self.temporary_directory.name) / "github-output"
        with mock.patch.dict(
            os.environ, {"GITHUB_OUTPUT": str(output)}
        ), mock.patch.object(
            reconcile,
            "registry_status",
            return_value=reconcile.MATCH,
        ):
            result = reconcile.main(
                [
                    "check",
                    "--registry",
                    "npm",
                    "--package",
                    "cmux-sdk",
                    "--version",
                    "1.0.0",
                    "--artifact",
                    str(self.artifact),
                    "--write-github-output",
                    "--github-output-name",
                    "npm",
                ]
            )
        self.assertEqual(result, 0)
        self.assertEqual(output.read_text(), "npm=match\n")


if __name__ == "__main__":
    unittest.main()
