package dev.cmux.android.core.pairing

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request

@Serializable
data class RelayPresenceEntry(
    val macDeviceId: String,
    val displayName: String? = null,
)

@Serializable
private data class RelayPresenceListResponse(val devices: List<RelayPresenceEntry> = emptyList())

/**
 * Lists the signed-in account's Macs currently reachable over the Cloudflare
 * mobile pairing relay (`workers/presence`'s `GET /v1/control/relay-presence`)
 * — each Mac announces itself there while its relay `/host` leg is up (see
 * `MobileHostCloudflareRelayRuntime`). Used for post-sign-in auto-discovery,
 * so pairing needs no QR scan or manual device-id entry.
 */
@Singleton
class RelayPresenceClient @Inject constructor() {
    private val client = OkHttpClient()
    private val json = Json { ignoreUnknownKeys = true }

    /** Best-effort: any failure (network, auth, malformed response) resolves
     * to an empty list rather than throwing — presence is a discovery aid,
     * and a caller with no candidates simply falls through to its own
     * fallback (manual pairing, or the DEBUG emulator bootstrap). */
    suspend fun listPresence(accessToken: String): List<RelayPresenceEntry> = withContext(Dispatchers.IO) {
        val base = MobileRelayDefaults.resolvedBaseUrl(isDebug = BuildConfig.DEBUG)
        val request = Request.Builder()
            .url("$base/v1/control/relay-presence")
            .header("Authorization", "Bearer $accessToken")
            .build()
        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@withContext emptyList()
                val body = response.body?.string() ?: return@withContext emptyList()
                json.decodeFromString<RelayPresenceListResponse>(body).devices
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}
