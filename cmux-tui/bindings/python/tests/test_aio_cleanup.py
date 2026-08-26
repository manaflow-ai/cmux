from __future__ import annotations

import asyncio
import unittest

from cmux.aio import _await_cleanup


class AioCleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_wrapped_cleanup_cancellation_is_not_retried(self) -> None:
        async def cleanup() -> None:
            raise asyncio.CancelledError

        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(_await_cleanup(cleanup()), timeout=0.2)

    async def test_caller_cancellation_is_deferred_until_cleanup_finishes(self) -> None:
        finished = asyncio.Event()

        async def cleanup() -> str:
            await asyncio.sleep(0)
            finished.set()
            return "done"

        task = asyncio.create_task(_await_cleanup(cleanup()))
        await asyncio.sleep(0)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(finished.is_set())
