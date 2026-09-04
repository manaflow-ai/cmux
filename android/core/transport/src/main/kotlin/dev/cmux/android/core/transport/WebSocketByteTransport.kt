package dev.cmux.android.core.transport

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * WebSocket transport for the cmux mobile sync protocol, tunneled through a
 * Cloudflare Durable Objects relay (`workers/presence`'s MobilePairingRelay
 * DO) instead of a direct TCP socket to the Mac.
 *
 * The relay DO is a dumb byte pipe between this device's `/client` leg and
 * the Mac's `/host` leg: it never parses cmux content, so the exact same
 * [MobileSyncFrameCodec] length-prefixed framing [TcpByteTransport] uses is
 * reused here — each WebSocket binary message carries one chunk of that same
 * byte stream (not necessarily a whole frame; the codec re-synchronizes
 * exactly like it does over TCP), keeping both ends of the wire protocol
 * completely unaware the transport changed.
 */
class WebSocketByteTransport(
    /** Full `wss://.../v1/mobile-relay/<macDeviceId>/client` URL. */
    private val relayUrl: String,
    /** Stack access token, sent as `Authorization: Bearer <token>` on the
     * upgrade request — the Worker requires it to open the socket at all. */
    private val accessToken: String,
    private val client: OkHttpClient = defaultClient,
) : MobileByteTransport {
    private var webSocket: WebSocket? = null
    private val opened = CompletableDeferred<Unit>()
    private val incomingChunks = Channel<ByteArray>(Channel.UNLIMITED)
    private val frameBuffer = mutableListOf<Byte>()
    private val pendingFrames = ArrayDeque<ByteArray>()

    /** Open the WebSocket and await the upgrade. Must be called before read/write. */
    override suspend fun connect() {
        val request = Request.Builder()
            .url(relayUrl)
            .header("Authorization", "Bearer $accessToken")
            .build()
        webSocket = client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened.complete(Unit)
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    incomingChunks.trySend(bytes.toByteArray())
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    // Transport-liveness heartbeats only (the relay DO's ping/pong
                    // convention); every cmux payload frame is a binary message.
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    incomingChunks.close()
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    val failure = t as? Exception ?: IOException(t)
                    opened.completeExceptionally(failure)
                    incomingChunks.close(failure)
                }
            },
        )
        opened.await()
    }

    override suspend fun writeFrame(payload: ByteArray) {
        val socket = webSocket ?: throw IOException("Not connected")
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        if (!socket.send(frame.toByteString())) {
            throw IOException("WebSocket send failed (relay socket closing or buffer full)")
        }
    }

    override suspend fun readFrame(): ByteArray? {
        while (pendingFrames.isEmpty()) {
            val chunk = incomingChunks.receiveCatching().getOrNull() ?: return null
            chunk.forEach { frameBuffer.add(it) }
            pendingFrames.addAll(MobileSyncFrameCodec.decodeFrames(frameBuffer))
        }
        return pendingFrames.removeFirst()
    }

    override fun close() {
        webSocket?.close(1000, "client closed")
        webSocket = null
        incomingChunks.close()
    }

    companion object {
        // WebSocket connections are long-lived; OkHttp's default read timeout
        // would tear one down mid-pairing session.
        private val defaultClient = OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }
}
