"""Policy-compliant standard-library client for the crates.io API and CDN."""

from __future__ import annotations

import http.client
import time
from collections.abc import Callable
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

API_ROOT = "https://crates.io/api/v1/crates"
STATIC_ROOT = "https://static.crates.io/crates"
USER_AGENT = (
    "cmux-sdk-publisher/1 "
    "(https://github.com/manaflow-ai/cmux; "
    "contact: https://github.com/manaflow-ai/cmux/issues)"
)
API_INTERVAL_SECONDS = 1.0
MAX_ATTEMPTS = 3
MAX_RETRY_AFTER_SECONDS = 30.0
RETRYABLE_HTTP_STATUSES = frozenset({403, 408, 425, 429, 500, 502, 503, 504})


class CratesIoRequestError(RuntimeError):
    """Raised when crates.io cannot be queried after bounded retries."""


class CratesIoClient:
    """Share pacing and retries across all crates.io requests in one operation."""

    def __init__(
        self,
        *,
        opener: Callable[..., Any] | None = None,
        monotonic: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
        api_interval: float = API_INTERVAL_SECONDS,
        max_attempts: int = MAX_ATTEMPTS,
    ) -> None:
        if api_interval < 0 or max_attempts <= 0:
            raise ValueError("crates.io client limits are invalid")
        self._opener = opener or urlopen
        self._monotonic = monotonic
        self._sleep = sleeper
        self._api_interval = api_interval
        self._max_attempts = max_attempts
        self._last_api_request: float | None = None

    def _pace_api(self) -> None:
        now = self._monotonic()
        if self._last_api_request is not None:
            remaining = self._last_api_request + self._api_interval - now
            if remaining > 0:
                self._sleep(remaining)
                now = self._monotonic()
        self._last_api_request = now

    def _retry_delay(self, error: HTTPError, *, paced: bool) -> float:
        minimum = self._api_interval if paced else 1.0
        raw_retry_after = error.headers.get("Retry-After") if error.headers else None
        if raw_retry_after is None or not raw_retry_after.isdigit():
            return minimum
        retry_after = float(raw_retry_after)
        if retry_after > MAX_RETRY_AFTER_SECONDS:
            raise CratesIoRequestError(
                "crates.io retry delay exceeds the bounded client limit"
            )
        return max(minimum, retry_after)

    def _request(self, url: str, accept: str, *, paced: bool) -> bytes | None:
        request = Request(
            url,
            headers={"Accept": accept, "User-Agent": USER_AGENT},
        )
        for attempt in range(self._max_attempts):
            if paced:
                self._pace_api()
            try:
                with self._opener(request, timeout=20) as response:
                    return response.read()
            except HTTPError as error:
                if error.code == 404:
                    error.close()
                    return None
                if (
                    error.code not in RETRYABLE_HTTP_STATUSES
                    or attempt + 1 == self._max_attempts
                ):
                    error.close()
                    raise CratesIoRequestError(
                        f"crates.io request failed with HTTP {error.code}"
                    ) from error
                try:
                    retry_delay = self._retry_delay(error, paced=paced)
                except CratesIoRequestError as retry_error:
                    raise retry_error from error
                finally:
                    error.close()
                self._sleep(retry_delay)
            except (URLError, OSError, http.client.IncompleteRead) as error:
                if attempt + 1 == self._max_attempts:
                    raise CratesIoRequestError(
                        "crates.io request failed before completing"
                    ) from error
                self._sleep(self._api_interval if paced else 1.0)
        raise AssertionError("bounded crates.io request loop did not return")

    def request_api(self, path: str) -> bytes | None:
        if not path.startswith("/") or "://" in path:
            raise ValueError("crates.io API path must be absolute and origin-relative")
        return self._request(
            f"{API_ROOT}{path}",
            "application/json",
            paced=True,
        )

    def download(self, package: str, version: str) -> bytes | None:
        if not package or not version:
            raise ValueError("crate package and version must be non-empty")
        encoded_package = quote(package, safe="")
        encoded_version = quote(version, safe="")
        return self._request(
            f"{STATIC_ROOT}/{encoded_package}/"
            f"{encoded_package}-{encoded_version}.crate",
            "application/octet-stream",
            paced=False,
        )
