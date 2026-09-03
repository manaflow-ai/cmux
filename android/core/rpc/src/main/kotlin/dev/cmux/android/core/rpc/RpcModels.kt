package dev.cmux.android.core.rpc

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** A pending RPC correlation entry. */
data class PendingRequest(
    val id: String,
    val completion: kotlinx.coroutines.CompletableDeferred<JsonObject>,
)

/** A server-pushed event envelope received on the shared connection. */
@Serializable
data class EventEnvelope(
    val topic: String,
    val payload: JsonObject,
    val stream_id: String? = null,
)

/** Workspace data returned by mobile.workspace.list. */
@Serializable
data class WorkspaceDto(
    val workspace_id: String,
    val title: String,
    val directory: String? = null,
    val terminals: List<TerminalDto> = emptyList(),
    val unread_count: Int = 0,
)

/** Terminal surface within a workspace. */
@Serializable
data class TerminalDto(
    val surface_id: String,
    val title: String? = null,
)
