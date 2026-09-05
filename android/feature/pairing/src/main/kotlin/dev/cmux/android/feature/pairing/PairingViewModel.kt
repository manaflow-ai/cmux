package dev.cmux.android.feature.pairing

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.AttachRoute
import dev.cmux.android.core.pairing.AttachTicket
import dev.cmux.android.core.pairing.AttachTicketDecoder
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.pairing.RelayConnectResult
import dev.cmux.android.core.pairing.RelayPairingConnector
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.transport.TcpByteTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

sealed interface PairingState {
    data object Idle : PairingState
    data object Scanning : PairingState
    data class Connecting(val host: String, val port: Int) : PairingState
    data class Success(val displayName: String?) : PairingState
    data class Error(val message: String) : PairingState
}

@HiltViewModel
class PairingViewModel @Inject constructor(
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
    private val relayPairingConnector: RelayPairingConnector,
) : ViewModel() {

    private val _state = MutableStateFlow<PairingState>(PairingState.Idle)
    val state: StateFlow<PairingState> = _state.asStateFlow()

    fun startScanning() {
        _state.value = PairingState.Scanning
    }

    fun onQrCodeScanned(rawUrl: String) {
        viewModelScope.launch(Dispatchers.IO) {
            when (val decoded = AttachTicketDecoder.decode(rawUrl)) {
                is AttachTicketDecoder.Result.Error -> {
                    _state.value = PairingState.Error("Invalid QR: ${decoded.reason}")
                }
                is AttachTicketDecoder.Result.Success -> {
                    connectAndPair(decoded.ticket)
                }
            }
        }
    }

    /**
     * DEBUG: pair through the Cloudflare relay using a Mac device id copied
     * from the Mac's Debug menu (or `list-workspaces` over its debug CLI),
     * instead of scanning a QR code — Android has no scanned-QR bootstrap for
     * this route kind yet, since [AttachTicketDecoder]'s v4 grammar requires
     * the device id up front (it is the relay's routing key, unlike the TCP
     * routes `mobile.host.status` can resolve post-connect).
     */
    fun connectViaRelay(macDeviceId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val trimmed = macDeviceId.trim()
            if (trimmed.isEmpty()) {
                _state.value = PairingState.Error("Mac device id is required")
                return@launch
            }
            val ticket = AttachTicket(
                routes = listOf(AttachRoute(AttachRoute.RouteKind.CLOUDFLARE_RELAY, trimmed, 0)),
                macUserId = null,
                macDeviceId = trimmed,
            )
            connectAndPair(ticket)
        }
    }

    private suspend fun connectAndPair(ticket: AttachTicket) {
        val relayRoute = ticket.routes.firstOrNull { it.kind == AttachRoute.RouteKind.CLOUDFLARE_RELAY }
        if (relayRoute != null) {
            connectViaRelayRoute(relayRoute)
            return
        }

        val route = ticket.routes.firstOrNull { it.kind == AttachRoute.RouteKind.TAILSCALE }
            ?: ticket.routes.firstOrNull()
            ?: run {
                _state.value = PairingState.Error("No usable route in ticket")
                return
            }

        // In emulator: always connect to 10.0.2.2 regardless of route kind.
        val host = if (isEmulator()) EMULATOR_HOST else route.host
        val port = if (isEmulator() || route.port <= 0) DEFAULT_PORT else route.port

        _state.value = PairingState.Connecting(host, port)

        try {
            val transport = TcpByteTransport(host, port)
            val session = MobileCoreRpcSession(transport)
            session.connect()

            // Send mobile.host.status (no auth required)
            val statusResponse = session.sendRequest("mobile.host.status")
            val result = statusResponse["result"]?.jsonObject
            val macDeviceId = result?.get("mac_device_id")?.jsonPrimitive?.content ?: ""
            val displayName = result?.get("mac_display_name")?.jsonPrimitive?.content

            pairedMacStore.save(ticket, macDeviceId, displayName, host, port)

            session.disconnect()
            _state.value = PairingState.Success(displayName)
        } catch (e: Exception) {
            _state.value = PairingState.Error("Connection failed: ${e.message}")
        }
    }

    /**
     * Unlike the TCP path, the relay Worker requires a valid Stack bearer
     * token to open the WebSocket at all (auth happens on the upgrade, not
     * per-RPC), so this is unreachable while signed out — a deliberate
     * behavior difference from the TCP fallback, not a bug: see
     * MobileHostCloudflareRelayRuntime / the relay worker route.
     */
    private suspend fun connectViaRelayRoute(route: AttachRoute) {
        val macDeviceId = route.host
        val accessToken = tokenStore.getAccessToken()
        if (accessToken.isNullOrBlank()) {
            _state.value = PairingState.Error("Sign in required for relay pairing")
            return
        }

        _state.value = PairingState.Connecting(macDeviceId, 0)

        _state.value = when (val result = relayPairingConnector.connect(macDeviceId, accessToken)) {
            is RelayConnectResult.Success -> PairingState.Success(result.displayName)
            is RelayConnectResult.Error -> PairingState.Error("Connection failed: ${result.message}")
        }
    }

    fun reset() {
        _state.value = PairingState.Idle
    }

    private fun isEmulator(): Boolean {
        return android.os.Build.HARDWARE == "ranchu"      // modern QEMU emulator
            || android.os.Build.HARDWARE == "goldfish"    // older emulator
            || android.os.Build.FINGERPRINT.startsWith("generic")
            || android.os.Build.FINGERPRINT.startsWith("unknown")
            || android.os.Build.MODEL.contains("Emulator")
            || android.os.Build.MODEL.contains("Android SDK built for x86")
            || android.os.Build.PRODUCT.contains("sdk_gphone")
    }

    companion object {
        const val EMULATOR_HOST = "10.0.2.2"
        const val DEFAULT_PORT = 58465
    }
}
