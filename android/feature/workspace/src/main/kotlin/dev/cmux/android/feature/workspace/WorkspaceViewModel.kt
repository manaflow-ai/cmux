package dev.cmux.android.feature.workspace

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.rpc.TerminalDto
import dev.cmux.android.core.rpc.WorkspaceDto
import dev.cmux.android.core.transport.TcpByteTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import javax.inject.Inject

sealed interface WorkspaceUiState {
    data object Loading : WorkspaceUiState
    data class Loaded(val workspaces: List<WorkspaceDto>) : WorkspaceUiState
    data class Error(val message: String) : WorkspaceUiState
}

@HiltViewModel
class WorkspaceViewModel @Inject constructor(
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow<WorkspaceUiState>(WorkspaceUiState.Loading)
    val state: StateFlow<WorkspaceUiState> = _state.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        loadWorkspaces()
    }

    private fun loadWorkspaces() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = WorkspaceUiState.Error("No paired Mac") }

                val transport = TcpByteTransport(mac.primaryHost, mac.primaryPort)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                val accessToken = tokenStore.getAccessToken()
                val response = rpcSession.sendRequest(
                    method = "mobile.workspace.list",
                    authToken = accessToken,
                )

                val resultArray = response["result"]?.jsonArray
                    ?: run {
                        val err = response["error"]?.jsonObject?.get("message")
                        _state.value = WorkspaceUiState.Error(err?.toString() ?: "No result")
                        return@launch
                    }

                val workspaces = resultArray.map { json.decodeFromJsonElement<WorkspaceDto>(it) }
                _state.value = WorkspaceUiState.Loaded(workspaces)
            } catch (e: Exception) {
                _state.value = WorkspaceUiState.Error(e.message ?: "Unknown error")
            }
        }
    }

    fun refresh() {
        _state.value = WorkspaceUiState.Loading
        loadWorkspaces()
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
    }
}
