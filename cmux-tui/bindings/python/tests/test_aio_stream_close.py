"""Queued reads of one async stream stop cleanly when the stream ends or is
closed (port of main #21351). Without the fix a second reader that waited on
the stream's lock used the stream's executor after its shutdown:
`RuntimeError: cannot schedule new futures after shutdown`."""

from __future__ import annotations

import asyncio
import unittest
from unittest.mock import Mock

from cmux._protocol import ResourceStream as SyncResourceStream, _StreamState
from cmux.aio import ResourceStream
from cmux.ids import StreamId
from cmux.models import StreamEnd


class AioStreamCleanupTests(unittest.IsolatedAsyncioTestCase):
    def make_stream(self):
        state = _StreamState(StreamId("stream_" + "a" * 32), lambda item: item, {})
        connection = Mock()
        connection.cancel_stream.side_effect = lambda state: state.finish(
            StreamEnd(state.stream_id, "canceled"), purge=True
        )
        owner = Mock()

        async def run_internal(function):
            return function()

        owner._run_internal = run_internal
        stream = ResourceStream(owner, SyncResourceStream(connection, state))
        self.addAsyncCleanup(stream.aclose)
        return stream, state, owner

    async def test_queued_reads_stop_when_stream_ends(self) -> None:
        stream, state, owner = self.make_stream()
        readers = [asyncio.create_task(stream.next(timeout=1)) for _ in range(4)]
        await asyncio.sleep(0)
        state.finish(StreamEnd(state.stream_id, "canceled"))

        results = await asyncio.wait_for(
            asyncio.gather(*readers, return_exceptions=True), timeout=2
        )

        self.assertTrue(
            all(isinstance(item, StopAsyncIteration) for item in results), results
        )
        owner._unregister_stream.assert_called_once_with(stream)
        with self.assertRaises(StopAsyncIteration):
            await stream.__anext__()

    async def test_queued_reads_stop_when_stream_is_closed(self) -> None:
        stream, _state, owner = self.make_stream()
        readers = [asyncio.create_task(stream.__anext__()) for _ in range(4)]
        await asyncio.sleep(0)
        await asyncio.wait_for(stream.aclose(), timeout=2)

        results = await asyncio.wait_for(
            asyncio.gather(*readers, return_exceptions=True), timeout=2
        )

        self.assertTrue(
            all(isinstance(item, StopAsyncIteration) for item in results), results
        )
        owner._unregister_stream.assert_called_once_with(stream)

    async def test_concurrent_reads_preserve_buffered_items_before_end(self) -> None:
        stream, state, _owner = self.make_stream()
        readers = [asyncio.create_task(stream.next(timeout=1)) for _ in range(4)]
        await asyncio.sleep(0)
        state.push({}, "1", None, "first")
        state.push({}, "2", None, "second")
        state.finish(StreamEnd(state.stream_id, "canceled"))

        results = await asyncio.wait_for(
            asyncio.gather(*readers, return_exceptions=True), timeout=2
        )

        self.assertEqual([item.item for item in results[:2]], ["first", "second"])
        self.assertTrue(
            all(isinstance(item, StopAsyncIteration) for item in results[2:]), results
        )


if __name__ == "__main__":
    unittest.main()
