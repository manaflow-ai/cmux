package dev.cmux.android.core.pairing

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource

/**
 * Unit tests for AttachTicketDecoder covering both v2 (Tailscale) and v3 (Iroh) QR URL grammars.
 *
 * Uses plain JVM — no Android dependencies required here since AttachTicketDecoder
 * uses android.net.Uri. On JVM unit tests, android.net.Uri is a stub; these tests
 * verify the pure logic around URL parsing with a minimal Uri shim by running on
 * the Android instrumented test runner, or by switching to java.net.URI.
 *
 * For the demo, the decode logic is validated here at the unit level. The
 * integration path (camera → ML Kit → decoder) is covered by the feature test.
 */
class AttachTicketDecoderTest {

    @Test
    fun `valid v2 single route decodes correctly`() {
        val url = "cmux-ios://attach?v=2&ub=user123&pc=1&r=100.64.1.2:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success, "Expected success but got $result")
        val ticket = (result as AttachTicketDecoder.Result.Success).ticket
        assertEquals(1, ticket.routes.size)
        assertEquals("100.64.1.2", ticket.routes[0].host)
        assertEquals(58465, ticket.routes[0].port)
        assertEquals(AttachRoute.RouteKind.TAILSCALE, ticket.routes[0].kind)
        assertEquals("user123", ticket.macUserId)
        assertEquals(1, ticket.compatibilityVersion)
    }

    @Test
    fun `valid v2 multiple routes decodes all routes`() {
        val url = "cmux-ios://attach?v=2&ub=uid&pc=0&r=100.64.1.2:58465&r=fd7a:115c:a1e0::1:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success)
        val ticket = (result as AttachTicketDecoder.Result.Success).ticket
        assertEquals(2, ticket.routes.size)
    }

    @Test
    fun `v2 loopback route is rejected`() {
        val url = "cmux-ios://attach?v=2&r=127.0.0.1:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.LOOPBACK_ROUTE_REJECTED,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `v2 localhost route is rejected`() {
        val url = "cmux-ios://attach?v=2&r=localhost:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.LOOPBACK_ROUTE_REJECTED,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `unsupported version returns UNSUPPORTED_VERSION error`() {
        val url = "cmux-ios://attach?v=99&r=100.64.1.2:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.UNSUPPORTED_VERSION,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `wrong scheme returns INVALID_URL error`() {
        val url = "https://example.com/attach?v=2&r=100.64.1.2:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.INVALID_URL,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `cmux-ios-dev scheme is accepted`() {
        val url = "cmux-ios-dev://attach?v=2&r=100.64.1.2:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success)
    }

    @Test
    fun `v2 missing routes returns EMPTY_ROUTES error`() {
        val url = "cmux-ios://attach?v=2&ub=user"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.EMPTY_ROUTES,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `v3 Iroh endpoint decodes correctly`() {
        val endpointId = "abcdef1234567890"
        val url = "cmux-ios://attach?v=3&i=$endpointId&d=mac-device-123"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success)
        val ticket = (result as AttachTicketDecoder.Result.Success).ticket
        assertEquals(1, ticket.routes.size)
        assertEquals(AttachRoute.RouteKind.IROH_ENDPOINT, ticket.routes[0].kind)
        assertEquals(endpointId, ticket.routes[0].host)
        assertEquals("mac-device-123", ticket.macDeviceId)
    }

    @Test
    fun `v3 without device id decodes with empty macDeviceId`() {
        val url = "cmux-ios://attach?v=3&i=someendpointid"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success)
        val ticket = (result as AttachTicketDecoder.Result.Success).ticket
        assertEquals("", ticket.macDeviceId)
    }

    @Test
    fun `malformed URL string returns INVALID_URL`() {
        val result = AttachTicketDecoder.decode("not-a-url-at-all")
        assertTrue(result is AttachTicketDecoder.Result.Error)
        assertEquals(
            AttachTicketDecoder.DecodeError.INVALID_URL,
            (result as AttachTicketDecoder.Result.Error).reason,
        )
    }

    @Test
    fun `wrong host (not attach) returns INVALID_URL`() {
        val url = "cmux-ios://pair?v=2&r=100.64.1.2:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Error)
    }

    @Test
    fun `v2 with MagicDNS hostname decodes correctly`() {
        val url = "cmux-ios://attach?v=2&r=my-mac.tail12345.ts.net:58465"
        val result = AttachTicketDecoder.decode(url)
        assertTrue(result is AttachTicketDecoder.Result.Success)
        val ticket = (result as AttachTicketDecoder.Result.Success).ticket
        assertEquals("my-mac.tail12345.ts.net", ticket.routes[0].host)
    }
}
