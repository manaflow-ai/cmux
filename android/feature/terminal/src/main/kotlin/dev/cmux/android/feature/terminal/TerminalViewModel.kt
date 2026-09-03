package dev.cmux.android.feature.terminal

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.transport.TcpByteTransport
import dev.cmux.termux.TerminalEmulator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import android.util.Base64
import javax.inject.Inject

sealed interface TerminalUiState {
    data object Connecting : TerminalUiState
    data class Connected(val lines: List<String>) : TerminalUiState
    data class Error(val message: String) : TerminalUiState
}

@HiltViewModel
class TerminalViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val workspaceId: String = checkNotNull(savedStateHandle["workspaceId"])
    private val surfaceId: String = checkNotNull(savedStateHandle["surfaceId"])

    private val emulator = TerminalEmulator(columns = 80, rows = 24)
    private val _state = MutableStateFlow<TerminalUiState>(TerminalUiState.Connecting)
    val state: StateFlow<TerminalUiState> = _state.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        emulator.onChange = {
            _state.value = TerminalUiState.Connected(emulator.screen)
        }
        connect()
    }

    private fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = TerminalUiState.Error("No paired Mac") }

                val transport = TcpByteTransport(mac.primaryHost, mac.primaryPort)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                // Subscribe to terminal.bytes events
                val collectJob = viewModelScope.launch(Dispatchers.IO) {
                    rpcSession.events.collect { envelope ->
                        if (envelope.topic == "terminal.bytes") {
                            val dataB64 = envelope.payload["data"]?.jsonPrimitive?.content
                            if (dataB64 != null) {
                                val bytes = Base64.decode(dataB64, Base64.DEFAULT)
                                emulator.feed(bytes)
                            }
                        }
                    }
                }

                // Subscribe to events stream
                val accessToken = tokenStore.getAccessToken()
                rpcSession.sendRequest(
                    method = "mobile.events.subscribe",
                    params = mapOf(
                        "topics" to JsonPrimitive("terminal.bytes"),
                        "surface_id" to JsonPrimitive(surfaceId),
                    ),
                    authToken = accessToken,
                )

                // Request terminal replay to get current screen
                rpcSession.sendRequest(
                    method = "mobile.terminal.replay",
                    params = mapOf(
                        "surface_id" to JsonPrimitive(surfaceId),
                        "workspace_id" to JsonPrimitive(workspaceId),
                    ),
                    authToken = accessToken,
                )

                _state.value = TerminalUiState.Connected(emulator.screen)
            } catch (e: Exception) {
                _state.value = TerminalUiState.Error(e.message ?: "Connection failed")
            }
        }
    }

    /** Send keyboard input to the terminal. */
    fun sendInput(text: String) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val rpc = session ?: return@launch
                val encoded = Base64.encodeToString(text.toByteArray(), Base64.NO_WRAP)
                rpc.sendRequest(
                    method = "mobile.terminal.input",
                    params = mapOf(
                        "surface_id" to JsonPrimitive(surfaceId),
                        "workspace_id" to JsonPrimitive(workspaceId),
                        "data" to JsonPrimitive(encoded),
                    ),
                    authToken = tokenStore.getAccessToken(),
                )
            } catch (e: Exception) {
                // Input delivery failure is non-fatal
            }
        }
    }

    /** Feed raw bytes into the emulator. Used by tests to bypass the network. */
    fun feedBytesForTest(bytes: ByteArray) {
        emulator.feed(bytes)
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
    }
}
