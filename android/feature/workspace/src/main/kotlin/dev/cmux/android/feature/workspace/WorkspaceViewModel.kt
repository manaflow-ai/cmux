package dev.cmux.android.feature.workspace

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.MobileTransportFactory
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.rpc.TerminalDto
import dev.cmux.android.core.rpc.WorkspaceDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

sealed interface WorkspaceUiState {
    data object Loading : WorkspaceUiState
    data class Loaded(val workspaces: List<WorkspaceDto>) : WorkspaceUiState
    data class Error(val message: String) : WorkspaceUiState
}

sealed interface WorkspaceCreateEvent {
    data class Created(val workspaceId: String, val surfaceId: String) : WorkspaceCreateEvent
    data class Failed(val message: String) : WorkspaceCreateEvent
}

@HiltViewModel
class WorkspaceViewModel @Inject constructor(
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow<WorkspaceUiState>(WorkspaceUiState.Loading)
    val state: StateFlow<WorkspaceUiState> = _state.asStateFlow()

    private val _createEvents = MutableSharedFlow<WorkspaceCreateEvent>()
    val createEvents: SharedFlow<WorkspaceCreateEvent> = _createEvents.asSharedFlow()

    private val _isCreating = MutableStateFlow(false)
    val isCreating: StateFlow<Boolean> = _isCreating.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        loadWorkspaces()
    }

    private fun loadWorkspaces() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = WorkspaceUiState.Error("No paired Mac") }

                val accessToken = tokenStore.getAccessToken()
                val transport = MobileTransportFactory.forPairedMac(mac, accessToken)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                val response = rpcSession.sendRequest(
                    method = "mobile.workspace.list",
                    authToken = accessToken,
                )

                val resultObject = response["result"]?.jsonObject
                    ?: run {
                        val err = response["error"]?.jsonObject?.get("message")
                        _state.value = WorkspaceUiState.Error(err?.toString() ?: "No result")
                        return@launch
                    }

                val resultArray = resultObject["workspaces"]?.jsonArray
                    ?: run {
                        _state.value = WorkspaceUiState.Error("Missing workspaces field")
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

    /** Creates a new workspace (with its default terminal) and emits [createEvents]. */
    fun createWorkspace() {
        viewModelScope.launch(Dispatchers.IO) {
            _isCreating.value = true
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch _createEvents.emit(WorkspaceCreateEvent.Failed("No paired Mac"))

                val accessToken = tokenStore.getAccessToken()
                val rpc = session ?: run {
                    val transport = MobileTransportFactory.forPairedMac(mac, accessToken)
                    MobileCoreRpcSession(transport).also {
                        it.connect()
                        session = it
                    }
                }

                val response = rpc.sendRequest(
                    method = "workspace.create",
                    authToken = accessToken,
                )

                val result = response["result"]?.jsonObject
                if (result == null) {
                    val err = response["error"]?.jsonObject?.get("message")
                    _createEvents.emit(WorkspaceCreateEvent.Failed(err?.toString() ?: "Create failed"))
                    return@launch
                }

                val createdId = result["created_workspace_id"]?.jsonPrimitive?.content
                val createdWorkspace = result["workspaces"]?.jsonArray
                    ?.mapNotNull { it as? JsonObject }
                    ?.firstOrNull { it["id"]?.jsonPrimitive?.content == createdId }
                val surfaceId = createdWorkspace?.get("terminals")?.jsonArray
                    ?.firstOrNull()?.let { it as? JsonObject }
                    ?.get("id")?.jsonPrimitive?.content

                if (createdId != null && surfaceId != null) {
                    _createEvents.emit(WorkspaceCreateEvent.Created(createdId, surfaceId))
                    refresh()
                } else {
                    _createEvents.emit(WorkspaceCreateEvent.Failed("Workspace created but no terminal was returned"))
                }
            } catch (e: Exception) {
                _createEvents.emit(WorkspaceCreateEvent.Failed(e.message ?: "Create failed"))
            } finally {
                _isCreating.value = false
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
    }
}
