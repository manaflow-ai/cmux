package dev.cmux.android.core.pairing

import io.mockk.*
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

/**
 * Unit tests for PairedMacStore using a mocked DAO.
 *
 * Full Room in-memory database tests would run on the instrumented test runner.
 * These tests validate the store's mapping and delegation logic.
 */
class PairedMacStoreTest {

    private val dao = mockk<PairedMacDao>()
    private val store = PairedMacStore(dao)

    @Test
    fun `save persists entity with correct fields`() = runTest {
        val slot = slot<PairedMacEntity>()
        coEvery { dao.upsert(capture(slot)) } just Runs

        val ticket = AttachTicket(
            routes = listOf(AttachRoute(AttachRoute.RouteKind.TAILSCALE, "100.64.1.2", 58465)),
            macUserId = "user-abc",
            compatibilityVersion = 1,
        )
        store.save(ticket, macDeviceId = "device-xyz", displayName = "My Mac", resolvedHost = "100.64.1.2", resolvedPort = 58465)

        coVerify { dao.upsert(any()) }
        assertEquals("device-xyz", slot.captured.macDeviceId)
        assertEquals("My Mac", slot.captured.displayName)
        assertEquals("100.64.1.2", slot.captured.primaryHost)
        assertEquals(58465, slot.captured.primaryPort)
        assertEquals("TAILSCALE", slot.captured.routeKind)
        assertEquals("user-abc", slot.captured.macUserId)
    }

    @Test
    fun `getLatest returns null when no macs paired`() = runTest {
        coEvery { dao.getLatest() } returns null
        assertNull(store.getLatest())
    }

    @Test
    fun `getLatest returns entity when one is paired`() = runTest {
        val entity = PairedMacEntity(
            macDeviceId = "dev-1",
            displayName = "Work Mac",
            primaryHost = "100.64.0.1",
            primaryPort = 58465,
            routeKind = "TAILSCALE",
            macUserId = null,
        )
        coEvery { dao.getLatest() } returns entity
        assertEquals("dev-1", store.getLatest()?.macDeviceId)
    }

    @Test
    fun `observeAll delegates to dao`() = runTest {
        val entities = listOf(
            PairedMacEntity("dev-1", "Mac 1", "100.64.0.1", 58465, "TAILSCALE", null),
        )
        every { dao.observeAll() } returns flowOf(entities)
        val result = store.observeAll().first()
        assertEquals(1, result.size)
        assertEquals("dev-1", result[0].macDeviceId)
    }

    @Test
    fun `deleteById delegates to dao`() = runTest {
        coEvery { dao.deleteById("dev-1") } just Runs
        store.deleteById("dev-1")
        coVerify { dao.deleteById("dev-1") }
    }

    @Test
    fun `save with empty macDeviceId generates synthetic id`() = runTest {
        val slot = slot<PairedMacEntity>()
        coEvery { dao.upsert(capture(slot)) } just Runs

        val ticket = AttachTicket(
            routes = listOf(AttachRoute(AttachRoute.RouteKind.TAILSCALE, "100.64.1.2", 58465)),
            macUserId = null,
        )
        store.save(ticket, macDeviceId = "", displayName = null, resolvedHost = "100.64.1.2", resolvedPort = 58465)

        assertTrue(slot.captured.macDeviceId.startsWith("unknown-"))
    }
}
