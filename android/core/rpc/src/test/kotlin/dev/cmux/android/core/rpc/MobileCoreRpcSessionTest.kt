package dev.cmux.android.core.rpc

import dev.cmux.android.core.transport.TcpByteTransport
import io.mockk.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class MobileCoreRpcSessionTest {

    @Test
    fun `sendRequest correlates response by id`() = runBlocking {
        val transport = mockk<TcpByteTransport>()
        coEvery { transport.connect() } just Runs
        coEvery { transport.close() } just Runs
        coEvery { transport.writeFrame(any()) } just Runs

        var readCount = 0
        coEvery { transport.readFrame() } coAnswers {
            if (readCount++ == 0) {
                """{"id":"fixed-id","result":{"status":"ok"}}""".toByteArray()
            } else {
                suspendCancellableCoroutine { /* park until cancelled */ }
            }
        }

        val session = MobileCoreRpcSession(transport)

        // Inject a pending entry BEFORE connect() so the reader loop finds it when
        // the first frame (the response) arrives — avoids a race where the reader
        // processes and discards the frame before the entry is registered.
        val deferred = CompletableDeferred<JsonObject>()
        val pendingField = session.javaClass.getDeclaredField("pending")
        pendingField.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pendingMap = pendingField.get(session)
            as java.util.concurrent.ConcurrentHashMap<String, PendingRequest>
        pendingMap["fixed-id"] = PendingRequest("fixed-id", deferred)

        session.connect()

        val result = withTimeout(1000) { deferred.await() }
        assertEquals("ok", result["result"]?.jsonObject?.get("status")?.jsonPrimitive?.content)

        session.disconnect()
    }

    @Test
    fun `events SharedFlow emits server-pushed event frames`() = runBlocking {
        val transport = mockk<TcpByteTransport>()
        coEvery { transport.connect() } just Runs
        coEvery { transport.writeFrame(any()) } just Runs
        coEvery { transport.close() } just Runs

        var readCount = 0
        coEvery { transport.readFrame() } coAnswers {
            if (readCount++ == 0) {
                """{"topic":"terminal.bytes","payload":{"data":"aGVsbG8="}}""".toByteArray()
            } else {
                suspendCancellableCoroutine { /* park until cancelled */ }
            }
        }

        val session = MobileCoreRpcSession(transport)

        // Subscribe BEFORE connect() so the collector is registered before the
        // reader emits the first frame. yield() lets the collectJob coroutine
        // run up to its first suspension point (registering on the SharedFlow).
        val received = mutableListOf<EventEnvelope>()
        val collectJob = launch { session.events.collect { received.add(it) } }
        yield()

        session.connect()

        withTimeout(1000) {
            while (received.isEmpty()) delay(10)
        }

        assertEquals(1, received.size)
        assertEquals("terminal.bytes", received[0].topic)

        collectJob.cancel()
        session.disconnect()
    }

    @Test
    fun `concurrent requests are correlated independently`() = runTest {
        val deferreds = (1..3).map { i ->
            val id = "req-$i"
            id to CompletableDeferred<JsonObject>()
        }

        deferreds.forEachIndexed { index, (id, deferred) ->
            launch {
                delay((index * 10).toLong())
                deferred.complete(buildJsonObject {
                    put("id", id)
                    put("result", buildJsonObject { put("n", index) })
                })
            }
        }

        val results = deferreds.map { (_, d) -> withTimeout(1000) { d.await() } }
        assertEquals(3, results.size)
        results.forEachIndexed { index, result ->
            assertEquals(index, result["result"]?.jsonObject?.get("n")?.jsonPrimitive?.int)
        }
    }

    @Test
    fun `event routing does not resolve pending requests`() {
        val eventObj = buildJsonObject {
            put("topic", "workspace.updated")
            put("payload", buildJsonObject { put("workspace_id", "ws-1") })
        }
        assertFalse(eventObj.containsKey("id"))
        assertTrue(eventObj.containsKey("topic"))
    }
}
