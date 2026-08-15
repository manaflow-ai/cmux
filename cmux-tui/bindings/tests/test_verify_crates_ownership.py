from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "verify_crates_ownership.py"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("verify_crates_ownership", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
ownership = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ownership)


class VerifyCratesOwnershipTests(unittest.TestCase):
    packages = ("cmux-sdk", "cmux-sidebar")
    repository = "https://github.com/manaflow-ai/cmux"
    owner_id = 431397
    owner_login = "lawrencecchen"

    def setUp(self) -> None:
        interval = mock.patch.object(
            ownership,
            "CRATES_IO_API_INTERVAL_SECONDS",
            0,
        )
        interval.start()
        self.addCleanup(interval.stop)

    def bootstrap_args(self, package: str = "cmux-sidebar") -> list[str]:
        return [
            "--package",
            package,
            "--repository",
            self.repository,
            "--owner-id",
            str(self.owner_id),
            "--owner-login",
            self.owner_login,
            "--bootstrap-ownership-only",
        ]

    def response(self, payload: object) -> io.BytesIO:
        return io.BytesIO(json.dumps(payload).encode())

    def registry_response(self, request: object, **_kwargs: object) -> io.BytesIO:
        url = str(getattr(request, "full_url", ""))
        package = next(name for name in self.packages if name in url)
        if url.endswith("/owners"):
            return self.response({
                "users": [{
                    "id": self.owner_id,
                    "login": self.owner_login,
                    "kind": "user",
                    "url": f"https://github.com/{self.owner_login}",
                }],
                "teams": [],
            })
        return self.response({
            "crate": {
                "id": package,
                "name": package,
                "repository": self.repository,
                "trustpub_only": True,
            }
        })

    def test_requires_the_exact_expected_owner_for_each_crate(self) -> None:
        with mock.patch.object(
            ownership,
            "urlopen",
            side_effect=self.registry_response,
        ) as urlopen:
            ownership.verify(
                self.packages,
                self.repository,
                self.owner_id,
                self.owner_login,
            )

        self.assertEqual(urlopen.call_count, 4)
        for call in urlopen.call_args_list:
            request = call.args[0]
            self.assertIn("github.com/manaflow-ai/cmux", request.headers["User-agent"])

    def test_rejects_an_unexpected_additional_owner(self) -> None:
        def response(request: object, **kwargs: object) -> io.BytesIO:
            payload = json.loads(self.registry_response(request, **kwargs).read())
            if str(getattr(request, "full_url", "")).endswith("/owners"):
                payload["users"].append({
                    "id": 1,
                    "login": "attacker",
                    "kind": "user",
                    "url": "https://github.com/attacker",
                })
            return self.response(payload)

        with mock.patch.object(ownership, "urlopen", side_effect=response), \
            self.assertRaisesRegex(ownership.OwnershipError, "owner"):
            ownership.verify(
                self.packages,
                self.repository,
                self.owner_id,
                self.owner_login,
            )

    def test_rejects_a_wrong_repository(self) -> None:
        def response(request: object, **kwargs: object) -> io.BytesIO:
            payload = json.loads(self.registry_response(request, **kwargs).read())
            if not str(getattr(request, "full_url", "")).endswith("/owners"):
                payload["crate"]["repository"] = "https://github.com/attacker/cmux"
            return self.response(payload)

        with mock.patch.object(ownership, "urlopen", side_effect=response), \
            self.assertRaisesRegex(ownership.OwnershipError, "repository"):
            ownership.verify(
                self.packages,
                self.repository,
                self.owner_id,
                self.owner_login,
            )

    def test_rejects_api_token_publishing(self) -> None:
        def response(request: object, **kwargs: object) -> io.BytesIO:
            payload = json.loads(self.registry_response(request, **kwargs).read())
            if not str(getattr(request, "full_url", "")).endswith("/owners"):
                payload["crate"]["trustpub_only"] = False
            return self.response(payload)

        with mock.patch.object(ownership, "urlopen", side_effect=response), \
            self.assertRaisesRegex(ownership.OwnershipError, "trusted publishing"):
            ownership.verify(
                self.packages,
                self.repository,
                self.owner_id,
                self.owner_login,
            )

    def test_bootstrap_mode_accepts_each_expected_crate_before_trusted_publishing(self) -> None:
        def response(request: object, **kwargs: object) -> io.BytesIO:
            payload = json.loads(self.registry_response(request, **kwargs).read())
            if not str(getattr(request, "full_url", "")).endswith("/owners"):
                payload["crate"]["trustpub_only"] = False
            return self.response(payload)

        for package in self.packages:
            with self.subTest(package=package), mock.patch.object(
                ownership, "urlopen", side_effect=response
            ):
                self.assertEqual(ownership.main(self.bootstrap_args(package)), 0)

    def test_bootstrap_mode_still_rejects_a_foreign_owner(self) -> None:
        def response(request: object, **kwargs: object) -> io.BytesIO:
            payload = json.loads(self.registry_response(request, **kwargs).read())
            if str(getattr(request, "full_url", "")).endswith("/owners"):
                payload["users"][0]["id"] = 1
                payload["users"][0]["login"] = "attacker"
                payload["users"][0]["url"] = "https://github.com/attacker"
            else:
                payload["crate"]["trustpub_only"] = False
            return self.response(payload)

        with mock.patch.object(ownership, "urlopen", side_effect=response):
            self.assertEqual(ownership.main(self.bootstrap_args()), 1)

    def test_bootstrap_mode_rejects_an_unlisted_reservation(self) -> None:
        with mock.patch.object(ownership, "urlopen") as urlopen:
            self.assertEqual(ownership.main(self.bootstrap_args("attacker-sdk")), 1)
        urlopen.assert_not_called()

    def test_bootstrap_mode_rejects_multiple_reservations(self) -> None:
        arguments = self.bootstrap_args("cmux-sdk")
        arguments[0:0] = ["--package", "cmux-sidebar"]
        with mock.patch.object(ownership, "urlopen") as urlopen:
            self.assertEqual(ownership.main(arguments), 1)
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
