package dev.cmux.android.core.transport

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketException

/**
 * Plain TCP transport for the cmux mobile sync protocol.
 *
 * Connects on [Dispatchers.IO], exposes [readFrame] / [writeFrame] coroutines
 * that block on IO without blocking the calling thread.
 */
class TcpByteTransport(
    private val host: String,
    private val port: Int,
) : Closeable {
    private var socket: Socket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null

    /** Establish the TCP connection. Must be called before read/write. */
    suspend fun connect() = withContext(Dispatchers.IO) {
        val s = Socket(host, port)
        s.tcpNoDelay = true
        s.soTimeout = 0  // blocking reads — coroutine cancellation handles timeouts
        socket = s
        inputStream = s.getInputStream()
        outputStream = s.getOutputStream()
    }

    /**
     * Write one framed payload to the wire. Thread-safe w.r.t. itself (callers
     * must serialize their own write order if ordering matters).
     */
    suspend fun writeFrame(payload: ByteArray) = withContext(Dispatchers.IO) {
        val out = outputStream ?: throw SocketException("Not connected")
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        out.write(frame)
        out.flush()
    }

    /**
     * Read and return the next complete JSON payload from the wire.
     * Suspends until a full frame arrives. Returns null when the connection closes.
     */
    suspend fun readFrame(): ByteArray? = withContext(Dispatchers.IO) {
        val inp = inputStream ?: return@withContext null
        val buffer = mutableListOf<Byte>()

        // Read until we have at least the 4-byte header.
        val headerBuf = ByteArray(MobileSyncFrameCodec.HEADER_BYTE_COUNT)
        var read = 0
        while (read < MobileSyncFrameCodec.HEADER_BYTE_COUNT) {
            val n = inp.read(headerBuf, read, headerBuf.size - read)
            if (n == -1) return@withContext null
            read += n
        }
        headerBuf.forEach { buffer.add(it) }

        // Determine payload length from header.
        val payloadLen = ((buffer[0].toInt() and 0xFF) shl 24) or
            ((buffer[1].toInt() and 0xFF) shl 16) or
            ((buffer[2].toInt() and 0xFF) shl 8) or
            (buffer[3].toInt() and 0xFF)

        if (payloadLen > MobileSyncFrameCodec.MAX_FRAME_BYTES) {
            throw FrameTooLargeException(payloadLen)
        }

        val payloadBuf = ByteArray(payloadLen)
        var payloadRead = 0
        while (payloadRead < payloadLen) {
            val n = inp.read(payloadBuf, payloadRead, payloadLen - payloadRead)
            if (n == -1) return@withContext null
            payloadRead += n
        }
        payloadBuf
    }

    override fun close() {
        socket?.close()
        socket = null
        inputStream = null
        outputStream = null
    }

    val isConnected: Boolean get() = socket?.isConnected == true && socket?.isClosed == false
}
