package dev.cmux.android.core.pairing

import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.transport.WebSocketByteTransport
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

sealed interface RelayConnectResult {
    data class Success(val macDeviceId: String, val displayName: String?) : RelayConnectResult
    data class Error(val message: String) : RelayConnectResult
}

/**
 * The one shared "dial a Mac over the Cloudflare relay, then persist the
 * pairing" path. Both the manual relay entry point ([dev.cmux.android
 * .feature.pairing.PairingViewModel]) and post-sign-in auto-discovery
 * (StartupViewModel) go through this connector, so there is exactly one
 * relay connect/persist flow rather than duplicated logic per entrypoint.
 *
 * Unlike the TCP path, the relay Worker requires a valid Stack bearer token
 * to open the WebSocket at all (auth happens on the upgrade, not per-RPC),
 * so this fails fast while signed out — a deliberate behavior difference
 * from the TCP fallback, not a bug: see MobileHostCloudflareRelayRuntime /
 * the relay worker route.
 */
@Singleton
class RelayPairingConnector @Inject constructor(
    private val pairedMacStore: PairedMacStore,
) {
    suspend fun connect(macDeviceId: String, accessToken: String): RelayConnectResult {
        val trimmed = macDeviceId.trim()
        if (trimmed.isEmpty()) {
            return RelayConnectResult.Error("Mac device id is required")
        }
        return try {
            val transport = WebSocketByteTransport(
                relayUrl = MobileRelayDefaults.clientRelayUrl(trimmed, isDebug = BuildConfig.DEBUG),
                accessToken = accessToken,
            )
            val session = MobileCoreRpcSession(transport)
            session.connect()

            val statusResponse = session.sendRequest("mobile.host.status")
            val result = statusResponse["result"]?.jsonObject
            val resolvedMacDeviceId = result?.get("mac_device_id")?.jsonPrimitive?.content
                ?.takeIf { it.isNotBlank() } ?: trimmed
            val displayName = result?.get("mac_display_name")?.jsonPrimitive?.content

            val route = AttachRoute(AttachRoute.RouteKind.CLOUDFLARE_RELAY, trimmed, 0)
            val ticket = AttachTicket(routes = listOf(route), macUserId = null, macDeviceId = trimmed)
            pairedMacStore.save(ticket, resolvedMacDeviceId, displayName, trimmed, 0)

            session.disconnect()
            RelayConnectResult.Success(resolvedMacDeviceId, displayName)
        } catch (e: Exception) {
            RelayConnectResult.Error(e.message ?: "connection failed")
        }
    }
}
