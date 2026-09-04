package dev.cmux.android.core.transport

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource

class MobileSyncFrameCodecTest {

    @Test
    fun `encode empty payload produces 4-byte header with zero length`() {
        val frame = MobileSyncFrameCodec.encodeFrame(ByteArray(0))
        assertEquals(4, frame.size)
        assertEquals(0, frame[0])
        assertEquals(0, frame[1])
        assertEquals(0, frame[2])
        assertEquals(0, frame[3])
    }

    @Test
    fun `encode small payload produces correct header and payload`() {
        val payload = "hello".toByteArray()
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        assertEquals(4 + payload.size, frame.size)
        // Header = 5 in big-endian
        assertEquals(0, frame[0])
        assertEquals(0, frame[1])
        assertEquals(0, frame[2])
        assertEquals(5, frame[3])
        // Payload bytes follow
        assertArrayEquals(payload, frame.sliceArray(4 until frame.size))
    }

    @Test
    fun `encode then decode round-trip for small payload`() {
        val payload = """{"method":"mobile.host.status"}""".toByteArray()
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        val buffer = frame.toMutableList()
        val decoded = MobileSyncFrameCodec.decodeFrames(buffer)
        assertEquals(1, decoded.size)
        assertArrayEquals(payload, decoded[0])
        assertTrue(buffer.isEmpty())
    }

    @Test
    fun `decode returns empty list for partial header`() {
        val buffer = mutableListOf<Byte>(0, 0)
        val frames = MobileSyncFrameCodec.decodeFrames(buffer)
        assertTrue(frames.isEmpty())
        assertEquals(2, buffer.size)
    }

    @Test
    fun `decode returns empty list when payload incomplete`() {
        // Header says 10 bytes but only 5 follow
        val buffer = mutableListOf<Byte>(0, 0, 0, 10, 1, 2, 3, 4, 5)
        val frames = MobileSyncFrameCodec.decodeFrames(buffer)
        assertTrue(frames.isEmpty())
        assertEquals(9, buffer.size)
    }

    @Test
    fun `decode multiple frames in one buffer`() {
        val p1 = "frame1".toByteArray()
        val p2 = "frame2".toByteArray()
        val combined = MobileSyncFrameCodec.encodeFrame(p1) + MobileSyncFrameCodec.encodeFrame(p2)
        val buffer = combined.toMutableList()
        val frames = MobileSyncFrameCodec.decodeFrames(buffer)
        assertEquals(2, frames.size)
        assertArrayEquals(p1, frames[0])
        assertArrayEquals(p2, frames[1])
        assertTrue(buffer.isEmpty())
    }

    @Test
    fun `encode throws for payload exceeding 8 MB`() {
        val tooBig = ByteArray(8 * 1024 * 1024 + 1)
        assertThrows(FrameTooLargeException::class.java) {
            MobileSyncFrameCodec.encodeFrame(tooBig)
        }
    }

    @Test
    fun `decode throws FrameTooLargeException for oversized declared length`() {
        // Craft a header claiming 9 MB
        val ninetyMB = 9 * 1024 * 1024
        val buffer = mutableListOf<Byte>(
            ((ninetyMB shr 24) and 0xFF).toByte(),
            ((ninetyMB shr 16) and 0xFF).toByte(),
            ((ninetyMB shr 8) and 0xFF).toByte(),
            (ninetyMB and 0xFF).toByte(),
        )
        assertThrows(FrameTooLargeException::class.java) {
            MobileSyncFrameCodec.decodeFrames(buffer)
        }
    }

    @Test
    fun `decode partial then rest gives correct result`() {
        val payload = "hello world".toByteArray()
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        // Feed first 5 bytes — incomplete
        val buffer = frame.take(5).toMutableList()
        val firstBatch = MobileSyncFrameCodec.decodeFrames(buffer)
        assertTrue(firstBatch.isEmpty())
        // Feed remaining bytes
        frame.drop(5).forEach { buffer.add(it) }
        val secondBatch = MobileSyncFrameCodec.decodeFrames(buffer)
        assertEquals(1, secondBatch.size)
        assertArrayEquals(payload, secondBatch[0])
    }

    @Test
    fun `round-trip with large payload`() {
        // Use 1 MB — large enough to exercise the codec path without the
        // quadratic cost of boxing 8 MB bytes into MutableList<Byte>.
        val payload = ByteArray(1024 * 1024) { it.toByte() }
        val frame = MobileSyncFrameCodec.encodeFrame(payload)
        val buffer = frame.toMutableList()
        val frames = MobileSyncFrameCodec.decodeFrames(buffer)
        assertEquals(1, frames.size)
        assertArrayEquals(payload, frames[0])
    }
}
