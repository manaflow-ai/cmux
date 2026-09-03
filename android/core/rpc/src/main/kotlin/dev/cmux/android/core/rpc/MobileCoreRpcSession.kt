package dev.cmux.android.core.rpc

import dev.cmux.android.core.transport.TcpByteTransport
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.serialization.json.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Multiplexed JSON-RPC session over one persistent TCP connection.
 *
 * Callers use [sendRequest] for request-response RPCs and [events] to
 * observe server-pushed event envelopes.
 *
 * Thread-safety: [sendRequest] and [sendRequestRaw] are coroutine-safe.
 * [connect] / [disconnect] must be called once each.
 */
class MobileCoreRpcSession(
    private val transport: TcpByteTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val pending = ConcurrentHashMap<String, PendingRequest>()
    private val _events = MutableSharedFlow<EventEnvelope>(extraBufferCapacity = 256)
    val events: SharedFlow<EventEnvelope> = _events.asSharedFlow()

    private var readerJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /** Connect the transport and start the background reader loop. */
    suspend fun connect() {
        transport.connect()
        readerJob = scope.launch { readLoop() }
    }

    /** Disconnect and cancel all pending requests. */
    fun disconnect() {
        readerJob?.cancel()
        scope.cancel()
        transport.close()
        pending.values.forEach { it.completion.cancel() }
        pending.clear()
    }

    /**
     * Send a JSON-RPC request and await its response.
     *
     * @param method The RPC method name (e.g. "mobile.workspace.list").
     * @param params Parameters map. The session injects a unique "id".
     * @param authToken Stack auth access token (required for most methods).
     * @return The full JSON response object.
     */
    suspend fun sendRequest(
        method: String,
        params: Map<String, JsonElement> = emptyMap(),
        authToken: String? = null,
    ): JsonObject {
        val id = UUID.randomUUID().toString()
        val requestObj = buildJsonObject {
            put("id", id)
            put("method", method)
            put("params", buildJsonObject { params.forEach { (k, v) -> put(k, v) } })
            if (authToken != null) {
                put("auth", buildJsonObject { put("stack_access_token", authToken) })
            }
        }
        return sendRequestRaw(id, requestObj.toString().toByteArray())
    }

    /** Low-level send with pre-serialized payload. Injects an id if missing. */
    suspend fun sendRequestRaw(
        id: String,
        payload: ByteArray,
    ): JsonObject {
        val deferred = CompletableDeferred<JsonObject>()
        pending[id] = PendingRequest(id, deferred)
        try {
            transport.writeFrame(payload)
            return deferred.await()
        } catch (e: CancellationException) {
            pending.remove(id)
            throw e
        }
    }

    private suspend fun readLoop() {
        try {
            while (coroutineContext.isActive) {
                val raw = transport.readFrame() ?: break
                handleFrame(raw)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Connection lost — cancel all pending with an error
            pending.values.forEach { it.completion.completeExceptionally(e) }
            pending.clear()
        }
    }

    private fun handleFrame(raw: ByteArray) {
        val text = raw.decodeToString()
        val obj = try {
            json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            return
        }

        val id = obj["id"]?.jsonPrimitive?.contentOrNull
        val topic = obj["topic"]?.jsonPrimitive?.contentOrNull

        when {
            // Response to a pending request
            id != null && (obj.containsKey("result") || obj.containsKey("error")) -> {
                pending.remove(id)?.completion?.complete(obj)
            }
            // Server-pushed event
            topic != null -> {
                val payload = obj["payload"]?.jsonObject ?: JsonObject(emptyMap())
                val streamId = obj["stream_id"]?.jsonPrimitive?.contentOrNull
                val envelope = EventEnvelope(topic = topic, payload = payload, stream_id = streamId)
                _events.tryEmit(envelope)
            }
        }
    }
}
