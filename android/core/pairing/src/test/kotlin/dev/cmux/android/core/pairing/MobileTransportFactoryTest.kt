package dev.cmux.android.core.pairing

import dev.cmux.android.core.transport.TcpByteTransport
import dev.cmux.android.core.transport.WebSocketByteTransport
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class MobileTransportFactoryTest {

    private fun mac(routeKind: AttachRoute.RouteKind, host: String = "10.0.2.2", port: Int = 58465) =
        PairedMacEntity(
            macDeviceId = "mac-1",
            displayName = "Test Mac",
            primaryHost = host,
            primaryPort = port,
            routeKind = routeKind.name,
            macUserId = null,
        )

    @Test
    fun `TCP route kinds build a TcpByteTransport`() {
        for (kind in listOf(AttachRoute.RouteKind.TAILSCALE, AttachRoute.RouteKind.IROH_ENDPOINT, AttachRoute.RouteKind.LOOPBACK)) {
            val transport = MobileTransportFactory.forPairedMac(mac(kind), accessToken = null)
            assertTrue(transport is TcpByteTransport, "expected TcpByteTransport for $kind")
        }
    }

    @Test
    fun `CLOUDFLARE_RELAY route kind builds a WebSocketByteTransport when signed in`() {
        val transport = MobileTransportFactory.forPairedMac(
            mac(AttachRoute.RouteKind.CLOUDFLARE_RELAY, host = "mac-device-abc"),
            accessToken = "token-123",
        )
        assertTrue(transport is WebSocketByteTransport)
    }

    @Test
    fun `CLOUDFLARE_RELAY route kind without a token throws`() {
        assertThrows(IllegalStateException::class.java) {
            MobileTransportFactory.forPairedMac(
                mac(AttachRoute.RouteKind.CLOUDFLARE_RELAY, host = "mac-device-abc"),
                accessToken = null,
            )
        }
    }
}
