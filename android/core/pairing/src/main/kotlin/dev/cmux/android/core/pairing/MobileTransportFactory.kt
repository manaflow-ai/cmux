package dev.cmux.android.core.pairing

import dev.cmux.android.core.transport.MobileByteTransport
import dev.cmux.android.core.transport.TcpByteTransport
import dev.cmux.android.core.transport.WebSocketByteTransport

/**
 * Builds the [MobileByteTransport] a paired Mac's stored route kind calls
 * for. The one shared construction path every feature that talks to a
 * paired Mac (workspace, terminal, browser, plus pairing itself) goes
 * through, so wiring in a new transport kind happens once instead of at each
 * call site (per the repo's shared-behavior policy for multi-entrypoint
 * mutation/connection paths).
 */
object MobileTransportFactory {
    /**
     * @param accessToken Required for [AttachRoute.RouteKind.CLOUDFLARE_RELAY]
     *   — the relay Worker requires a Stack bearer token to open the
     *   WebSocket at all, unlike the raw TCP listener, which authenticates
     *   per-RPC instead of per-connection. Ignored for every other route kind.
     * @throws IllegalStateException if [mac]'s route kind is the Cloudflare
     *   relay and [accessToken] is null (not signed in).
     */
    fun forPairedMac(mac: PairedMacEntity, accessToken: String?): MobileByteTransport {
        return if (mac.routeKind == AttachRoute.RouteKind.CLOUDFLARE_RELAY.name) {
            checkNotNull(accessToken) {
                "Sign-in required to reach a Mac paired over the Cloudflare relay"
            }
            WebSocketByteTransport(
                relayUrl = MobileRelayDefaults.clientRelayUrl(
                    macDeviceId = mac.primaryHost,
                    isDebug = BuildConfig.DEBUG,
                ),
                accessToken = accessToken,
            )
        } else {
            TcpByteTransport(mac.primaryHost, mac.primaryPort)
        }
    }
}
