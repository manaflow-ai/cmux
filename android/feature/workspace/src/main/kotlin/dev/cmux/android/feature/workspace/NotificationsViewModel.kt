package dev.cmux.android.feature.workspace

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.MobileTransportFactory
import dev.cmux.android.core.pairing.PairedMacStore
import dev.cmux.android.core.rpc.MobileCoreRpcSession
import dev.cmux.android.core.rpc.NotificationFeedItemDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.util.UUID
import javax.inject.Inject

sealed interface NotificationsUiState {
    data object Loading : NotificationsUiState
    data class Loaded(val notifications: List<NotificationFeedItemDto>) : NotificationsUiState
    data class Error(val message: String) : NotificationsUiState
}

/**
 * Foreground-only notification feed: driven by the live `mobile.events.subscribe`
 * connection (a `workspace.updated` nudge triggers a re-fetch), matching iOS's
 * Notifications tab while connected. Real background push (FCM) is a follow-up
 * that needs a Firebase project — out of scope here.
 */
@HiltViewModel
class NotificationsViewModel @Inject constructor(
    private val pairedMacStore: PairedMacStore,
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow<NotificationsUiState>(NotificationsUiState.Loading)
    val state: StateFlow<NotificationsUiState> = _state.asStateFlow()

    private var session: MobileCoreRpcSession? = null

    init {
        connect()
    }

    private fun connect() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val mac = pairedMacStore.getLatest()
                    ?: return@launch run { _state.value = NotificationsUiState.Error("No paired Mac") }

                val accessToken = tokenStore.getAccessToken()
                val transport = MobileTransportFactory.forPairedMac(mac, accessToken)
                val rpcSession = MobileCoreRpcSession(transport)
                rpcSession.connect()
                session = rpcSession

                viewModelScope.launch(Dispatchers.IO) {
                    rpcSession.events.collect { envelope ->
                        if (envelope.topic == "workspace.updated") {
                            fetchNotifications(rpcSession, accessToken)
                        }
                    }
                }

                rpcSession.sendRequest(
                    method = "mobile.events.subscribe",
                    params = mapOf(
                        "stream_id" to JsonPrimitive(UUID.randomUUID().toString()),
                        "topics" to buildJsonArray {
                            add(JsonPrimitive("workspace.updated"))
                        },
                    ),
                    authToken = accessToken,
                )

                fetchNotifications(rpcSession, accessToken)
            } catch (e: Exception) {
                _state.value = NotificationsUiState.Error(e.message ?: "Connection failed")
            }
        }
    }

    private suspend fun fetchNotifications(rpcSession: MobileCoreRpcSession, accessToken: String?) {
        try {
            val response = rpcSession.sendRequest(
                method = "notification.feed.list",
                authToken = accessToken,
            )
            val result = response["result"]?.jsonObject
                ?: run {
                    val err = response["error"]?.jsonObject?.get("message")
                    _state.value = NotificationsUiState.Error(err?.toString() ?: "No result")
                    return
                }
            val items = result["notifications"]?.jsonArray
                ?.map { json.decodeFromJsonElement<NotificationFeedItemDto>(it) }
                ?: emptyList()
            _state.value = NotificationsUiState.Loaded(items.sortedByDescending { it.created_at })
        } catch (e: Exception) {
            _state.value = NotificationsUiState.Error(e.message ?: "Fetch failed")
        }
    }

    fun refresh() {
        val rpcSession = session
        if (rpcSession == null) {
            connect()
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            fetchNotifications(rpcSession, tokenStore.getAccessToken())
        }
    }

    fun markRead(id: String) {
        val rpcSession = session ?: return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val accessToken = tokenStore.getAccessToken()
                rpcSession.sendRequest(
                    method = "notification.feed.mark_read",
                    params = mapOf(
                        "notification_ids" to buildJsonArray { add(JsonPrimitive(id)) },
                    ),
                    authToken = accessToken,
                )
                fetchNotifications(rpcSession, accessToken)
            } catch (e: Exception) {
                _state.value = NotificationsUiState.Error(e.message ?: "Mark read failed")
            }
        }
    }

    fun markAllRead() {
        val rpcSession = session ?: return
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val accessToken = tokenStore.getAccessToken()
                rpcSession.sendRequest(
                    method = "notification.feed.mark_all_read",
                    authToken = accessToken,
                )
                fetchNotifications(rpcSession, accessToken)
            } catch (e: Exception) {
                _state.value = NotificationsUiState.Error(e.message ?: "Mark all read failed")
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        session?.disconnect()
    }
}
