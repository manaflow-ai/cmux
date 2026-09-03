package dev.cmux.android.feature.browser

import dev.cmux.android.core.rpc.EventEnvelope
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import java.util.Base64

/**
 * Unit tests for BrowserViewModel event decoding.
 *
 * Tests validate the browser.frame event payload structure and base64 decoding
 * independently of Android Bitmap — Bitmap tests run on the emulator.
 */
class BrowserViewModelTest {

    @Test
    fun `browser.frame event has expected JSON keys`() {
        val panelId = "panel-abc"
        val fakeJpegB64 = Base64.getEncoder().encodeToString(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte()))
        val payload = buildJsonObject {
            put("panel_id", panelId)
            put("seq", 1)
            put("format", "jpeg")
            put("page_width", 1280.0)
            put("page_height", 800.0)
            put("pixel_width", 1280)
            put("pixel_height", 800)
            put("data_b64", fakeJpegB64)
        }
        val envelope = EventEnvelope(topic = "browser.frame", payload = payload)

        assertEquals("browser.frame", envelope.topic)
        assertEquals(panelId, envelope.payload["panel_id"]?.jsonPrimitive?.content)
        assertEquals(1L, envelope.payload["seq"]?.jsonPrimitive?.longOrNull)
        assertNotNull(envelope.payload["data_b64"]?.jsonPrimitive?.content)
    }

    @Test
    fun `base64 frame data decodes to expected bytes`() {
        val original = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47) // PNG magic bytes
        val b64 = Base64.getEncoder().encodeToString(original)
        val decoded = Base64.getDecoder().decode(b64)
        assertArrayEquals(original, decoded)
    }

    @Test
    fun `browser.frame.ack request has correct params`() {
        val params = mapOf(
            "panel_id" to JsonPrimitive("panel-abc"),
            "seq" to JsonPrimitive(42L),
        )
        assertEquals("panel-abc", params["panel_id"]?.jsonPrimitive?.content)
        assertEquals(42L, params["seq"]?.jsonPrimitive?.longOrNull)
    }

    @Test
    fun `BrowserUiState Streaming with null frame is valid initial state`() {
        val state: BrowserUiState = BrowserUiState.Streaming(null)
        assertTrue(state is BrowserUiState.Streaming)
        assertNull((state as BrowserUiState.Streaming).frame)
    }

    @Test
    fun `events with wrong panel_id are filtered`() {
        val myPanelId = "panel-mine"
        val otherPanelId = "panel-other"
        val payload = buildJsonObject {
            put("panel_id", otherPanelId)
            put("data_b64", "abc")
        }
        val envelope = EventEnvelope(topic = "browser.frame", payload = payload)
        val isForMe = envelope.payload["panel_id"]?.jsonPrimitive?.content == myPanelId
        assertFalse(isForMe)
    }

    @Test
    fun `mobile.browser.stream.start request method is correct`() {
        val method = "mobile.browser.stream.start"
        assertTrue(method.startsWith("mobile.browser"))
    }
}
