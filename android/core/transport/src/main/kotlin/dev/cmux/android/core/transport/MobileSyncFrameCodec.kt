package dev.cmux.android.core.transport

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Length-prefixed frame codec matching the iOS MobileSyncFrameCodec.
 *
 * Wire format: [UInt32 big-endian length (4 bytes)][JSON payload bytes]
 * Max frame: 8 MB. Decode up to 256 frames per read batch.
 */
object MobileSyncFrameCodec {
    const val HEADER_BYTE_COUNT = 4
    const val MAX_FRAME_BYTES = 8 * 1024 * 1024
    const val MAX_FRAMES_PER_BATCH = 256

    /** Encode [payload] as a length-prefixed frame. Throws if payload exceeds 8 MB. */
    fun encodeFrame(payload: ByteArray): ByteArray {
        if (payload.size > MAX_FRAME_BYTES) {
            throw FrameTooLargeException(payload.size)
        }
        val buffer = ByteBuffer.allocate(HEADER_BYTE_COUNT + payload.size)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    /**
     * Decode as many complete frames as possible from [buffer].
     * Consumed bytes are removed from the front of [buffer].
     * Returns up to [MAX_FRAMES_PER_BATCH] frames.
     */
    fun decodeFrames(buffer: MutableList<Byte>): List<ByteArray> {
        val frames = mutableListOf<ByteArray>()
        var consumed = 0

        while (buffer.size - consumed >= HEADER_BYTE_COUNT) {
            if (frames.size >= MAX_FRAMES_PER_BATCH) {
                throw TooManyFramesException(MAX_FRAMES_PER_BATCH)
            }
            val length = readBigEndianInt(buffer, consumed)
            if (length < 0 || length > MAX_FRAME_BYTES) {
                throw FrameTooLargeException(length)
            }
            val totalNeeded = HEADER_BYTE_COUNT + length
            if (buffer.size - consumed < totalNeeded) break

            val payload = ByteArray(length) { buffer[consumed + HEADER_BYTE_COUNT + it] }
            frames.add(payload)
            consumed += totalNeeded
        }

        if (consumed > 0) {
            repeat(consumed) { buffer.removeAt(0) }
        }
        return frames
    }

    private fun readBigEndianInt(buffer: List<Byte>, offset: Int): Int {
        return ((buffer[offset].toInt() and 0xFF) shl 24) or
            ((buffer[offset + 1].toInt() and 0xFF) shl 16) or
            ((buffer[offset + 2].toInt() and 0xFF) shl 8) or
            (buffer[offset + 3].toInt() and 0xFF)
    }
}

class FrameTooLargeException(size: Int) : IOException("Frame too large: $size bytes")
class TooManyFramesException(max: Int) : IOException("Too many frames in batch (max $max)")
