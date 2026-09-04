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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import android.util.Base64
import android.util.Log
import java.util.UUID
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

    // Render-grid path: explicit text rows from the Mac's structured grid format
    private val screenRows = mutableListOf<String>()
    private var useRenderGrid = false

    // Bytes path: ANSI emulator fallback
    private val emulator = TerminalEmulator(columns = 80, rows = 24)

    private val _state = MutableStateFlow<TerminalUiState>(TerminalUiState.Connecting)
    val state: StateFlow<TerminalUiState> = _state.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        emulator.onChange = {
            if (!useRenderGrid) publishState()
        }
        connect()
    }

    private fun publishState() {
        val raw = if (useRenderGrid) screenRows.toList() else emulator.screen
        val lines = raw.map { it.trimEnd() }
        val lastNonBlank = lines.indexOfLast { it.isNotBlank() }
        _state.value = TerminalUiState.Connected(
            if (lastNonBlank < 0) emptyList() else lines.subList(0, lastNonBlank + 1)
        )
    }

    /**
     * Parse a render_grid JSON object (from replay result or event payload) into
     * plain text rows and apply them to [screenRows].
     *
     * Mirrors MobileTerminalRenderGridFrame.plainRows() from the iOS source.
     */
    private fun applyRenderGrid(grid: JsonObject) {
        val numRows = (grid["rows"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return
        val isFull = (grid["full"] as? JsonPrimitive)?.content?.toBooleanStrictOrNull() ?: true
        val clearedRowIndices = (grid["cleared_rows"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.content?.toIntOrNull() }
            ?: emptyList()
        val rowSpans = (grid["row_spans"] as? JsonArray) ?: return

        if (isFull) {
            // Full snapshot: rebuild all rows from scratch
            val rows = Array(numRows) { StringBuilder() }
            rowSpans
                .mapNotNull { it as? JsonObject }
                .sortedWith(compareBy(
                    { (it["row"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0 },
                    { (it["column"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0 }
                ))
                .forEach { span ->
                    val row = (span["row"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return@forEach
                    val col = (span["column"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return@forEach
                    val text = (span["text"] as? JsonPrimitive)?.content ?: return@forEach
                    if (row !in 0 until numRows) return@forEach
                    val sb = rows[row]
                    while (sb.length < col) sb.append(' ')
                    sb.append(text)
                }
            screenRows.clear()
            screenRows.addAll(rows.map { it.toString() })
            Log.d("TerminalVM", "RenderGrid full: $numRows rows, ${rowSpans.size} spans, non-blank=${screenRows.count { it.isNotBlank() }}")
        } else {
            // Delta: extend rows if needed, clear explicit cleared rows, patch changed rows
            while (screenRows.size < numRows) screenRows.add("")
            for (idx in clearedRowIndices) {
                if (idx in screenRows.indices) screenRows[idx] = ""
            }
            val spansByRow = rowSpans
                .mapNotNull { it as? JsonObject }
                .groupBy { (it["row"] as? JsonPrimitive)?.content?.toIntOrNull() ?: -1 }
            for ((rowIdx, spans) in spansByRow) {
                if (rowIdx !in 0 until numRows || rowIdx !in screenRows.indices) continue
                val sb = StringBuilder(screenRows[rowIdx])
                spans
                    .sortedBy { (it["column"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0 }
                    .forEach { span ->
                        val col = (span["column"] as? JsonPrimitive)?.content?.toIntOrNull() ?: return@forEach
                        val text = (span["text"] as? JsonPrimitive)?.content ?: return@forEach
                        while (sb.length < col) sb.append(' ')
                        val end = col + text.length
                        if (end <= sb.length) sb.replace(col, end, text)
                        else { sb.setLength(col); sb.append(text) }
                    }
                screenRows[rowIdx] = sb.toString()
            }
            Log.d("TerminalVM", "RenderGrid delta: ${spansByRow.size} rows updated")
        }

        useRenderGrid = true
        publishState()
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

                // Collect terminal events (both render_grid and bytes)
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
                                    emulator.feed(bytes)
                                }
                            }
                            else -> Log.d("TerminalVM", "Event: topic=${envelope.topic}")
                        }
                    }
                }

                val accessToken = tokenStore.getAccessToken()

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

                // Request replay — Mac returns render_grid (preferred) or data_b64 (fallback)
                val replayResponse = rpcSession.sendRequest(
                    method = "mobile.terminal.replay",
                    params = mapOf(
                        "surface_id" to JsonPrimitive(surfaceId),
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
                            emulator.feed(Base64.decode(b64, Base64.DEFAULT))
                        }
                    }
                    replayResult?.containsKey("snapshot_data_b64") == true -> {
                        val b64 = (replayResult["snapshot_data_b64"] as? JsonPrimitive)?.content
                        if (b64 != null) {
                            Log.d("TerminalVM", "Replay: using snapshot_data_b64, len=${b64.length}")
                            emulator.feed(Base64.decode(b64, Base64.DEFAULT))
                        }
                    }
                    else -> Log.w("TerminalVM", "Replay: no usable content in result")
                }

                publishState()
            } catch (e: Exception) {
                Log.e("TerminalVM", "Connection error", e)
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
            } catch (_: Exception) {
                // Input delivery failure is non-fatal
            }
        }
    }

    /** Feed raw bytes into the emulator directly. Used by tests. */
    fun feedBytesForTest(bytes: ByteArray) {
        emulator.feed(bytes)
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
    }
}
