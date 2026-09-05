package dev.cmux.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.pairing.RelayConnectResult
import dev.cmux.android.core.pairing.RelayPairingConnector
import dev.cmux.android.core.pairing.RelayPresenceClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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
        // Auto-discover and pair over the Cloudflare relay — any build, any
        // device: once signed in, nothing further should be required of the
        // user. The emulator-only TCP bootstrap (tryAutoConnect) is
        // intentionally NOT used as a fallback here — only call it
        // explicitly when asked to, so a relay failure is visible (Pairing
        // screen) instead of silently masked by TCP.
        if (tryAutoConnectViaRelay()) return Destination.Workspaces
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
        val accessToken = tokenStore.getAccessToken() ?: return false
        val device = try {
            relayPresenceClient.listPresence(accessToken).firstOrNull()
        } catch (_: Exception) {
            null
        } ?: return false
        return when (relayPairingConnector.connect(device.macDeviceId, accessToken)) {
            is RelayConnectResult.Success -> true
            is RelayConnectResult.Error -> false
        }
    }

    /** Called after sign-in to re-run the startup logic. */
    fun onSignedIn() {
        _destination.value = Destination.Loading
        viewModelScope.launch(Dispatchers.IO) {
            _destination.value = resolve()
        }
    }
}
