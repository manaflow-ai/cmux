package dev.cmux.android.ui.navigation

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.BuildConfig
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.AttachRoute
import dev.cmux.android.core.pairing.AttachTicket
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.pairing.RelayConnectResult
import dev.cmux.android.core.pairing.RelayPairingConnector
import dev.cmux.android.core.pairing.RelayPresenceClient
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.transport.TcpByteTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

@HiltViewModel
class StartupViewModel @Inject constructor(
    private val tokenStore: StackAuthTokenStore,
    private val pairedMacStore: PairedMacStore,
    private val relayPresenceClient: RelayPresenceClient,
    private val relayPairingConnector: RelayPairingConnector,
) : ViewModel() {

    sealed interface Destination {
        data object Loading : Destination
        data object SignIn : Destination
        data object Pairing : Destination
        data object Workspaces : Destination
    }

    private val _destination = MutableStateFlow<Destination>(Destination.Loading)
    val destination: StateFlow<Destination> = _destination.asStateFlow()

    init {
        viewModelScope.launch(Dispatchers.IO) {
            _destination.value = resolve()
        }
    }

    private suspend fun resolve(): Destination {
        if (!tokenStore.isSignedIn) return Destination.SignIn
        if (pairedMacStore.getLatest() != null) return Destination.Workspaces
        // Auto-discover and pair over the Cloudflare relay first — the path
        // real (non-emulator) devices use, any build. In DEBUG, fall back to
        // the emulator-only direct-TCP bootstrap (10.0.2.2:58465, the
        // debug socket's loopback mapping to the host Mac) when relay
        // discovery doesn't find a Mac — e.g. the emulator has no route to
        // the Cloudflare relay's presence directory, or the debug relay
        // worker instance and the Mac's aren't the same one. Without this
        // fallback the emulator has no way to reach Workspaces at all.
        if (tryAutoConnectViaRelay()) return Destination.Workspaces
        if (BuildConfig.DEBUG && tryAutoConnectViaTcp()) return Destination.Workspaces
        return Destination.Pairing
    }

    /**
     * Lists this account's Macs currently reachable over the relay (see
     * `RelayPresenceClient`) and dials the first one through the same shared
     * connect/persist path the manual relay entry point uses
     * (`RelayPairingConnector`) — no QR scan, no manual device-id entry.
     * Best-effort: any failure (no token, no Mac announcing, connect
     * failure) just returns false so the caller falls through to its next
     * option.
     */
    private suspend fun tryAutoConnectViaRelay(): Boolean {
        val accessToken = tokenStore.getAccessToken()
        if (accessToken == null) {
            Log.w(TAG, "tryAutoConnectViaRelay: no access token, falling to Pairing")
            return false
        }
        val device = try {
            relayPresenceClient.listPresence(accessToken).firstOrNull()
        } catch (e: Exception) {
            Log.w(TAG, "tryAutoConnectViaRelay: listPresence threw", e)
            null
        }
        if (device == null) {
            Log.w(TAG, "tryAutoConnectViaRelay: no Mac announcing presence, falling to Pairing")
            return false
        }
        return when (val result = relayPairingConnector.connect(device.macDeviceId, accessToken)) {
            is RelayConnectResult.Success -> true
            is RelayConnectResult.Error -> {
                Log.w(TAG, "tryAutoConnectViaRelay: connect(${device.macDeviceId}) failed: ${result.message}")
                false
            }
        }
    }

    /** Emulator-only bootstrap: dials the host Mac directly over the AVD's
     * loopback mapping, no Cloudflare relay or QR/device-id needed. Mirrors
     * the manual TCP pairing path in `PairingViewModel`. */
    private suspend fun tryAutoConnectViaTcp(): Boolean {
        return try {
            val host = "10.0.2.2"
            val port = 58465
            val transport = TcpByteTransport(host, port)
            val session = MobileCoreRpcSession(transport)
            session.connect()
            val statusResponse = session.sendRequest("mobile.host.status")
            val result = statusResponse["result"]?.jsonObject
            val macDeviceId = result?.get("mac_device_id")?.jsonPrimitive?.content ?: ""
            val displayName = result?.get("mac_display_name")?.jsonPrimitive?.content
            val ticket = AttachTicket(
                routes = listOf(AttachRoute(AttachRoute.RouteKind.LOOPBACK, host, port)),
                macUserId = null,
            )
            pairedMacStore.save(ticket, macDeviceId, displayName, host, port)
            session.disconnect()
            true
        } catch (e: Exception) {
            Log.w(TAG, "tryAutoConnectViaTcp: failed", e)
            false
        }
    }

    /** Called after sign-in to re-run the startup logic. */
    fun onSignedIn() {
        _destination.value = Destination.Loading
        viewModelScope.launch(Dispatchers.IO) {
            _destination.value = resolve()
        }
    }

    private companion object {
        const val TAG = "StartupViewModel"
    }
}
