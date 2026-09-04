package dev.cmux.android.core.transport

import java.io.Closeable

/**
 * A byte-stream transport for the cmux mobile sync protocol: a length-prefixed
 * JSON frame stream (see [MobileSyncFrameCodec]), regardless of what carries
 * the bytes underneath — a raw TCP socket ([TcpByteTransport]) or a Cloudflare
 * Durable Objects WebSocket relay ([WebSocketByteTransport]).
 *
 * [dev.cmux.android.core.rpc.MobileCoreRpcSession] depends only on this
 * interface, so swapping transports never touches RPC/event handling.
 */
interface MobileByteTransport : Closeable {
    /** Establish the connection. Must be called before read/write. */
    suspend fun connect()

    /**
     * Write one framed payload to the wire. Thread-safe w.r.t. itself (callers
     * must serialize their own write order if ordering matters).
     */
    suspend fun writeFrame(payload: ByteArray)

    /**
     * Read and return the next complete JSON payload from the wire.
     * Suspends until a full frame arrives. Returns null when the connection closes.
     */
    suspend fun readFrame(): ByteArray?
}
