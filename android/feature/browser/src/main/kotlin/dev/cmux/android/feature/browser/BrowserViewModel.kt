package dev.cmux.android.feature.browser

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.transport.TcpByteTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

sealed interface BrowserUiState {
    data object Connecting : BrowserUiState
    data class Streaming(val frame: Bitmap?) : BrowserUiState
    data class Error(val message: String) : BrowserUiState
}

@HiltViewModel
class BrowserViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val workspaceId: String = checkNotNull(savedStateHandle["workspaceId"])
    private val panelId: String = checkNotNull(savedStateHandle["panelId"])

    private val _state = MutableStateFlow<BrowserUiState>(BrowserUiState.Connecting)
    val state: StateFlow<BrowserUiState> = _state.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        connect()
    }

    private fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = BrowserUiState.Error("No paired Mac") }

                val transport = TcpByteTransport(mac.primaryHost, mac.primaryPort)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                val accessToken = tokenStore.getAccessToken()

                // Subscribe to browser.frame events
                viewModelScope.launch(Dispatchers.IO) {
                    rpcSession.events.collect { envelope ->
                        if (envelope.topic == "browser.frame") {
                            val framePanel = envelope.payload["panel_id"]?.jsonPrimitive?.content
                            if (framePanel == panelId) {
                                val dataB64 = envelope.payload["data_b64"]?.jsonPrimitive?.content
                            val sequence = envelope.payload["seq"]?.jsonPrimitive?.longOrNull ?: 0L
                                if (dataB64 != null) {
                                    val bytes = Base64.decode(dataB64, Base64.DEFAULT)
                                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                    _state.value = BrowserUiState.Streaming(bitmap)

                                    // ACK the frame
                                    try {
                                        rpcSession.sendRequest(
                                            method = "mobile.browser.frame.ack",
                                            params = mapOf(
                                                "panel_id" to JsonPrimitive(panelId),
                                                "seq" to JsonPrimitive(sequence),
                                            ),
                                            authToken = accessToken,
                                        )
                                    } catch (_: Exception) {}
                                }
                            }
                        }
                    }
                }

                // Start the browser stream
                rpcSession.sendRequest(
                    method = "mobile.browser.stream.start",
                    params = mapOf(
                        "panel_id" to JsonPrimitive(panelId),
                        "workspace_id" to JsonPrimitive(workspaceId),
                    ),
                    authToken = accessToken,
                )

                _state.value = BrowserUiState.Streaming(null)
            } catch (e: Exception) {
                _state.value = BrowserUiState.Error(e.message ?: "Connection failed")
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch(Dispatchers.IO) {
            try {
                session?.sendRequest(
                    method = "mobile.browser.stream.stop",
                    params = mapOf("panel_id" to JsonPrimitive(panelId)),
                    authToken = tokenStore.getAccessToken(),
                )
            } catch (_: Exception) {}
            session?.disconnect()
        }
    }
}
