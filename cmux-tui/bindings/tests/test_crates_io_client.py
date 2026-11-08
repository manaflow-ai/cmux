from __future__ import annotations

import importlib.util
import io
import unittest
from pathlib import Path
from urllib.error import HTTPError

SCRIPT = Path(__file__).resolve().parents[1] / "crates_io_client.py"


class CratesIoClientTests(unittest.TestCase):
    def load_client(self):
        self.assertTrue(SCRIPT.is_file(), "shared crates.io client is missing")
        spec = importlib.util.spec_from_file_location("crates_io_client", SCRIPT)
        assert spec is not None
        assert spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_paces_api_requests_and_uses_the_static_download_host(self) -> None:
        module = self.load_client()
        now = [10.0]
        waits: list[float] = []
        requests: list[object] = []

        def monotonic() -> float:
            return now[0]

        def sleep(seconds: float) -> None:
            waits.append(seconds)
            now[0] += seconds

        def open_request(request: object, **_kwargs: object) -> io.BytesIO:
            requests.append(request)
            url = str(getattr(request, "full_url", ""))
            if url.startswith("https://static.crates.io/"):
                return io.BytesIO(b"crate bytes")
            return io.BytesIO(b'{"crate":{"name":"cmux-client"}}')

        client = module.CratesIoClient(
            opener=open_request,
            monotonic=monotonic,
            sleeper=sleep,
        )
        self.assertIsNotNone(client.request_api("/cmux-client/1.0.0"))
        self.assertIsNotNone(client.request_api("/cmux-client"))
        self.assertEqual(
            client.download("cmux-client", "1.0.0"),
            b"crate bytes",
        )

        urls = [str(getattr(request, "full_url", "")) for request in requests]
        self.assertEqual(
            urls,
            [
                "https://crates.io/api/v1/crates/cmux-client/1.0.0",
                "https://crates.io/api/v1/crates/cmux-client",
                "https://static.crates.io/crates/cmux-client/cmux-client-1.0.0.crate",
            ],
        )
        self.assertEqual(len(waits), 1)
        self.assertAlmostEqual(waits[0], 1.0)
        for request in requests:
            self.assertIn(
                "https://github.com/manaflow-ai/cmux",
                request.headers["User-agent"],
            )

    def test_retries_a_rate_limited_api_request_after_retry_after(self) -> None:
        module = self.load_client()
        now = [20.0]
        waits: list[float] = []
        attempts = [0]

        def monotonic() -> float:
            return now[0]

        def sleep(seconds: float) -> None:
            waits.append(seconds)
            now[0] += seconds

        def open_request(request: object, **_kwargs: object) -> io.BytesIO:
            attempts[0] += 1
            if attempts[0] == 1:
                raise HTTPError(
                    str(getattr(request, "full_url", "")),
                    429,
                    "rate limited",
                    {"Retry-After": "2"},
                    None,
                )
            return io.BytesIO(b"{}")

        client = module.CratesIoClient(
            opener=open_request,
            monotonic=monotonic,
            sleeper=sleep,
        )
        self.assertEqual(client.request_api("/cmux-client"), b"{}")
        self.assertEqual(attempts[0], 2)
        self.assertGreaterEqual(sum(waits), 2.0)


if __name__ == "__main__":
    unittest.main()
