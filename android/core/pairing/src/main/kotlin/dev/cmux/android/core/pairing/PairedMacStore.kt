package dev.cmux.android.core.pairing

import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PairedMacStore @Inject constructor(
    private val dao: PairedMacDao,
) {
    fun observeAll(): Flow<List<PairedMacEntity>> = dao.observeAll()

    suspend fun getLatest(): PairedMacEntity? = dao.getLatest()

    suspend fun save(
        ticket: AttachTicket,
        macDeviceId: String,
        displayName: String?,
        resolvedHost: String,
        resolvedPort: Int,
    ) {
        val primary = ticket.routes.firstOrNull()
        dao.upsert(
            PairedMacEntity(
                macDeviceId = macDeviceId.ifBlank { "unknown-${System.currentTimeMillis()}" },
                displayName = displayName,
                primaryHost = resolvedHost,
                primaryPort = resolvedPort,
                routeKind = primary?.kind?.name ?: "UNKNOWN",
                macUserId = ticket.macUserId,
            )
        )
    }

    suspend fun deleteById(id: String) = dao.deleteById(id)
}
