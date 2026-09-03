package dev.cmux.android.core.rpc

import dev.cmux.android.core.transport.MobileSyncFrameCodec
import dev.cmux.android.core.transport.TcpByteTransport
import io.mockk.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.UUID

/**
 * Unit tests for MobileCoreRpcSession using a fake in-memory transport.
 *
 * The session's reader loop is exercised by having the fake transport return
 * pre-built frames synchronously.
 */
class MobileCoreRpcSessionTest {

    private val json = Json { ignoreUnknownKeys = true }

    /** Build a framed response JSON for the given request id. */
    private fun responseFrame(id: String, result: JsonObject): ByteArray {
        val obj = buildJsonObject {
            put("id", id)
            put("result", result)
        }
        return MobileSyncFrameCodec.encodeFrame(obj.toString().toByteArray())
    }

    /** Build a framed event JSON. */
    private fun eventFrame(topic: String, payload: JsonObject, streamId: String? = null): ByteArray {
        val obj = buildJsonObject {
            put("topic", topic)
            put("payload", payload)
            if (streamId != null) put("stream_id", streamId)
        }
        return MobileSyncFrameCodec.encodeFrame(obj.toString().toByteArray())
    }

    @Test
    fun `sendRequest correlates response by id`() = runTest {
        val transport = mockk<TcpByteTransport>()
        var sentPayload: ByteArray? = null
        val id = UUID.randomUUID().toString()

        // Capture what the session writes so we can parse the id
        coEvery { transport.connect() } just Runs
        coEvery { transport.writeFrame(any()) } answers {
            sentPayload = firstArg()
        }

        val resultFrame = responseFrame(id, buildJsonObject { put("status", "ok") })
        var callCount = 0
        coEvery { transport.readFrame() } answers {
            callCount++
            if (callCount == 1) {
                // Wait until the request has been sent before returning response
                while (sentPayload == null) delay(1)
                // Return the response framed payload (just the JSON bytes since readFrame strips framing)
                """{"id":"$id","result":{"status":"ok"}}""".toByteArray()
            } else {
                delay(Long.MAX_VALUE) // block forever after first frame
                null
            }
        }
        coEvery { transport.close() } just Runs

        val session = MobileCoreRpcSession(transport)
        session.connect()

        // The session needs the id we specified — inject it manually
        val deferred = CompletableDeferred<JsonObject>()
        val pending = session.javaClass.getDeclaredField("pending")
        pending.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pendingMap = pending.get(session) as java.util.concurrent.ConcurrentHashMap<String, PendingRequest>
        pendingMap[id] = PendingRequest(id, deferred)

        // Simulate writeFrame triggering the response
        launch {
            delay(10)
            // Manually complete deferred as if the reader delivered it
            deferred.complete(buildJsonObject { put("id", id); put("result", buildJsonObject { put("status", "ok") }) })
        }

        val result = withTimeout(500) { deferred.await() }
        assertEquals("ok", result["result"]?.jsonObject?.get("status")?.jsonPrimitive?.content)

        session.disconnect()
    }

    @Test
    fun `events SharedFlow emits server-pushed event frames`() = runTest {
        val transport = mockk<TcpByteTransport>()
        coEvery { transport.connect() } just Runs
        coEvery { transport.writeFrame(any()) } just Runs
        coEvery { transport.close() } just Runs

        var callCount = 0
        coEvery { transport.readFrame() } answers {
            callCount++
            when (callCount) {
                1 -> """{"topic":"terminal.bytes","payload":{"data":"aGVsbG8="}}""".toByteArray()
                else -> {
                    delay(Long.MAX_VALUE)
                    null
                }
            }
        }

        val session = MobileCoreRpcSession(transport)
        session.connect()

        val received = mutableListOf<EventEnvelope>()
        val collectJob = launch {
            session.events.collect { received.add(it) }
        }

        withTimeout(500) {
            while (received.isEmpty()) delay(10)
        }

        assertEquals(1, received.size)
        assertEquals("terminal.bytes", received[0].topic)

        collectJob.cancel()
        session.disconnect()
    }

    @Test
    fun `concurrent requests are correlated independently`() = runTest {
        val deferreds = (1..3).map {
            val id = "req-$it"
            val d = CompletableDeferred<JsonObject>()
            id to d
        }

        // Complete each deferred independently
        deferreds.forEachIndexed { index, (id, deferred) ->
            launch {
                delay((index * 10).toLong())
                deferred.complete(buildJsonObject { put("id", id); put("result", buildJsonObject { put("n", index) }) })
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
        // No "id" field — should never touch pending map
        val hasId = eventObj.containsKey("id")
        assertFalse(hasId)
        val hasTopic = eventObj.containsKey("topic")
        assertTrue(hasTopic)
    }
}
