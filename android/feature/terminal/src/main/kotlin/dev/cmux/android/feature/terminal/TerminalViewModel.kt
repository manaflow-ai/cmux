package dev.cmux.android.feature.terminal

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.ghosttyvt.GhosttyRenderSnapshot
import dev.cmux.android.core.ghosttyvt.GhosttyTerminal
import dev.cmux.android.core.ghosttyvt.RenderGridFrame
import dev.cmux.android.core.ghosttyvt.RenderGridVtSynthesizer
import dev.cmux.android.core.pairing.MobileTransportFactory
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.rpc.TerminalDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import android.util.Base64
import android.util.Log
import java.util.UUID
import javax.inject.Inject

sealed interface TerminalUiState {
    data object Connecting : TerminalUiState
    data class Connected(val snapshot: GhosttyRenderSnapshot) : TerminalUiState
    data class Error(val message: String) : TerminalUiState
}

@HiltViewModel
class TerminalViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val json = Json { ignoreUnknownKeys = true }
    private val workspaceId: String = checkNotNull(savedStateHandle["workspaceId"])
    private var surfaceId: String = checkNotNull(savedStateHandle["surfaceId"])

    // Real libghostty-vt terminal: VT bytes in (synthesized from render_grid,
    // or raw PTY bytes on the fallback path), a paintable snapshot out.
    private val ghosttyTerminal = GhosttyTerminal(columns = 80, rows = 24)

    private val _state = MutableStateFlow<TerminalUiState>(TerminalUiState.Connecting)
    val state: StateFlow<TerminalUiState> = _state.asStateFlow()

    private val _activeSurfaceId = MutableStateFlow(surfaceId)
    val activeSurfaceId: StateFlow<String> = _activeSurfaceId.asStateFlow()

    /** Sibling terminals in this workspace, for the terminal-switcher dropdown. */
    private val _siblingTerminals = MutableStateFlow<List<TerminalDto>>(emptyList())
    val siblingTerminals: StateFlow<List<TerminalDto>> = _siblingTerminals.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        connect()
    }

    private fun publishState() {
        val snapshot = ghosttyTerminal.snapshot() ?: return
        _state.value = TerminalUiState.Connected(snapshot)
    }

    /** Decodes a render_grid JSON object (from replay result or event payload), synthesizes
     * the equivalent VT bytes, and feeds them into the real libghostty-vt terminal. */
    private fun applyRenderGrid(grid: JsonObject) {
        try {
            val frame = json.decodeFromJsonElement<RenderGridFrame>(grid)
            // The Mac's terminal may have more rows/columns than our fixed 80x24 default
            // (set at construction, before any frame has arrived). Without this, cursor
            // positioning bytes for a row beyond our configured height get clamped by
            // libghostty-vt into the last row instead of actually existing, corrupting
            // content instead of just clipping it. No-ops if dimensions are unchanged.
            ghosttyTerminal.resize(frame.columns, frame.rows)
            ghosttyTerminal.write(RenderGridVtSynthesizer.patchBytes(frame))
            publishState()
        } catch (e: Exception) {
            Log.w("TerminalVM", "applyRenderGrid decode failed", e)
        }
    }

    private fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = TerminalUiState.Error("No paired Mac") }

                val accessToken = tokenStore.getAccessToken()
                val transport = MobileTransportFactory.forPairedMac(mac, accessToken)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                // Collect terminal events (both render_grid and bytes) — persists across
                // surface switches, since it's the same underlying connection.
                viewModelScope.launch(Dispatchers.IO) {
                    rpcSession.events.collect { envelope ->
                        when (envelope.topic) {
                            "terminal.render_grid" -> {
                                // Payload is either {"render_grid": {...frame...}} (wrapped)
                                // or the bare frame directly — try wrapped first, then bare
                                val grid = (envelope.payload["render_grid"] as? JsonObject)
                                    ?: envelope.payload
                                Log.d("TerminalVM", "Got terminal.render_grid event, wrapped=${envelope.payload.containsKey("render_grid")}")
                                applyRenderGrid(grid)
                            }
                            "terminal.bytes" -> {
                                val dataB64 = (envelope.payload["data_b64"] as? JsonPrimitive)?.content
                                if (dataB64 != null) {
                                    val bytes = Base64.decode(dataB64, Base64.DEFAULT)
                                    Log.d("TerminalVM", "Got terminal.bytes: ${bytes.size} bytes")
                                    ghosttyTerminal.write(bytes)
                                    publishState()
                                }
                            }
                            "workspace.updated" -> fetchSiblingTerminals(rpcSession, accessToken)
                            else -> Log.d("TerminalVM", "Event: topic=${envelope.topic}")
                        }
                    }
                }

                // Subscribe to both render_grid and bytes — the Mac will use whichever it prefers
                val streamId = UUID.randomUUID().toString()
                val subscribeResponse = rpcSession.sendRequest(
                    method = "mobile.events.subscribe",
                    params = mapOf(
                        "stream_id" to JsonPrimitive(streamId),
                        "topics" to buildJsonArray {
                            add(JsonPrimitive("terminal.render_grid"))
                            add(JsonPrimitive("terminal.bytes"))
                            add(JsonPrimitive("workspace.updated"))
                        },
                    ),
                    authToken = accessToken,
                )
                Log.d("TerminalVM", "Subscribe response keys: ${subscribeResponse.keys}")

                fetchSiblingTerminals(rpcSession, accessToken)
                attachToSurface(rpcSession, accessToken, surfaceId)
            } catch (e: Exception) {
                Log.e("TerminalVM", "Connection error", e)
                _state.value = TerminalUiState.Error(e.message ?: "Connection failed")
            }
        }
    }

    /** Replays and applies the given surface's current content. Reusable for the initial
     * connect and for switching to a different terminal in the same workspace. */
    private suspend fun attachToSurface(
        rpcSession: MobileCoreRpcSession,
        accessToken: String?,
        targetSurfaceId: String,
    ) {
        ghosttyTerminal.reset()

        // Request replay — Mac returns render_grid (preferred) or data_b64 (fallback)
        val replayResponse = rpcSession.sendRequest(
            method = "mobile.terminal.replay",
            params = mapOf(
                "surface_id" to JsonPrimitive(targetSurfaceId),
                "workspace_id" to JsonPrimitive(workspaceId),
            ),
            authToken = accessToken,
        )
        Log.d("TerminalVM", "Replay response keys: ${replayResponse.keys}")
        val replayResult = (replayResponse["result"] as? JsonObject)
        Log.d("TerminalVM", "Replay result keys: ${replayResult?.keys}")

        when {
            replayResult?.containsKey("render_grid") == true -> {
                val grid = replayResult["render_grid"] as? JsonObject
                if (grid != null) {
                    Log.d("TerminalVM", "Replay: using render_grid, keys=${grid.keys}")
                    applyRenderGrid(grid)
                }
            }
            replayResult?.containsKey("data_b64") == true -> {
                val b64 = (replayResult["data_b64"] as? JsonPrimitive)?.content
                if (b64 != null) {
                    Log.d("TerminalVM", "Replay: using data_b64, len=${b64.length}")
                    ghosttyTerminal.write(Base64.decode(b64, Base64.DEFAULT))
                }
            }
            replayResult?.containsKey("snapshot_data_b64") == true -> {
                val b64 = (replayResult["snapshot_data_b64"] as? JsonPrimitive)?.content
                if (b64 != null) {
                    Log.d("TerminalVM", "Replay: using snapshot_data_b64, len=${b64.length}")
                    ghosttyTerminal.write(Base64.decode(b64, Base64.DEFAULT))
                }
            }
            else -> Log.w("TerminalVM", "Replay: no usable content in result")
        }

        publishState()
    }

    /** Fetches this workspace's terminal list, for the terminal-switcher dropdown. */
    private suspend fun fetchSiblingTerminals(rpcSession: MobileCoreRpcSession, accessToken: String?) {
        try {
            val response = rpcSession.sendRequest(
                method = "mobile.workspace.list",
                params = mapOf("workspace_id" to JsonPrimitive(workspaceId)),
                authToken = accessToken,
            )
            val workspaces = response["result"]?.jsonObject?.get("workspaces")?.jsonArray ?: return
            val ws = workspaces.mapNotNull { it as? JsonObject }
                .firstOrNull { it["id"]?.jsonPrimitive?.content == workspaceId }
            val terminals = ws?.get("terminals")?.jsonArray
                ?.map { json.decodeFromJsonElement<TerminalDto>(it) }
                ?: emptyList()
            _siblingTerminals.value = terminals
        } catch (e: Exception) {
            Log.w("TerminalVM", "fetchSiblingTerminals failed", e)
        }
    }

    /** Switches the screen to a different terminal within the same workspace. */
    fun switchSurface(newSurfaceId: String) {
        if (newSurfaceId == surfaceId) return
        val rpcSession = session ?: return
        surfaceId = newSurfaceId
        _activeSurfaceId.value = newSurfaceId
        _state.value = TerminalUiState.Connecting
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val accessToken = tokenStore.getAccessToken()
                rpcSession.sendRequest(
                    method = "mobile.surface.focus",
                    params = mapOf(
                        "workspace_id" to JsonPrimitive(workspaceId),
                        "surface_id" to JsonPrimitive(newSurfaceId),
                    ),
                    authToken = accessToken,
                )
                attachToSurface(rpcSession, accessToken, newSurfaceId)
            } catch (e: Exception) {
                Log.e("TerminalVM", "switchSurface failed", e)
                _state.value = TerminalUiState.Error(e.message ?: "Switch failed")
            }
        }
    }

    /** Send keyboard input to the terminal. */
    fun sendInput(text: String) {
        // Sending input is a strong signal the user wants to follow the live
        // output again, matching normal terminal behavior (typing snaps you
        // back to the bottom even if you'd scrolled into history).
        ghosttyTerminal.scrollToBottom()
        publishState()
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val rpc = session ?: return@launch
                val response = rpc.sendRequest(
                    method = "mobile.terminal.input",
                    params = mapOf(
                        "surface_id" to JsonPrimitive(surfaceId),
                        "workspace_id" to JsonPrimitive(workspaceId),
                        "text" to JsonPrimitive(text),
                    ),
                    authToken = tokenStore.getAccessToken(),
                )
                if (response.containsKey("error")) {
                    Log.w("TerminalVM", "sendInput error: ${response["error"]}")
                }
            } catch (e: Exception) {
                Log.e("TerminalVM", "sendInput failed", e)
            }
        }
    }

    /**
     * Scrolls the terminal's viewport into scrollback by [deltaRows] (negative = up/older,
     * positive = down/newer) — driven by a vertical drag gesture on [TerminalCanvas]. This
     * only changes which rows [GhosttyTerminal.snapshot] reports; it never touches content.
     */
    fun scroll(deltaRows: Int) {
        if (deltaRows == 0) return
        ghosttyTerminal.scrollBy(deltaRows)
        publishState()
    }

    /** Feed raw bytes into the real terminal directly. Used by tests. */
    fun feedBytesForTest(bytes: ByteArray) {
        ghosttyTerminal.write(bytes)
        publishState()
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
        ghosttyTerminal.close()
    }
}
