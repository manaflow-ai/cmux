package dev.cmux.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.BuildConfig
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.AttachRoute
import dev.cmux.android.core.pairing.AttachTicket
import dev.cmux.android.core.pairing.PairedMacStore
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
        if (BuildConfig.DEBUG) {
            val paired = tryAutoConnect()
            return if (paired) Destination.Workspaces else Destination.Pairing
        }
        return Destination.Pairing
    }

    /** Called after sign-in to re-run the startup logic. */
    fun onSignedIn() {
        _destination.value = Destination.Loading
        viewModelScope.launch(Dispatchers.IO) {
            _destination.value = resolve()
        }
    }

    private suspend fun tryAutoConnect(): Boolean {
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
        } catch (_: Exception) {
            false
        }
    }
}
