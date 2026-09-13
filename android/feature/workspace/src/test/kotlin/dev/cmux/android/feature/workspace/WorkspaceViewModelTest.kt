package dev.cmux.android.feature.workspace

import dev.cmux.android.core.rpc.TerminalDto
import dev.cmux.android.core.rpc.WorkspaceDto
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

/**
 * Unit tests for WorkspaceViewModel mapping logic.
 *
 * Full integration (connecting to the RPC session) is covered by emulator tests.
 * Here we validate the DTO mapping and state model independently.
 */
class WorkspaceViewModelTest {

    @Test
    fun `WorkspaceDto maps title and directory correctly`() {
        val dto = WorkspaceDto(
            id = "ws-1",
            title = "My Project",
            current_directory = "/home/user/project",
            terminals = listOf(TerminalDto(id = "s-1", title = "zsh")),
            unread_count = 3,
        )
        assertEquals("ws-1", dto.id)
        assertEquals("My Project", dto.title)
        assertEquals("/home/user/project", dto.current_directory)
        assertEquals(1, dto.terminals.size)
        assertEquals("s-1", dto.terminals[0].id)
        assertEquals(3, dto.unread_count)
    }

    @Test
    fun `WorkspaceDto defaults unread_count to null`() {
        val dto = WorkspaceDto(id = "ws-2", title = "No unread")
        assertNull(dto.unread_count)
    }

    @Test
    fun `Loaded state with multiple workspaces has correct count`() {
        val workspaces = (1..5).map { i ->
            WorkspaceDto(id = "ws-$i", title = "Workspace $i")
        }
        val state = WorkspaceUiState.Loaded(workspaces)
        assertEquals(5, (state as WorkspaceUiState.Loaded).workspaces.size)
    }

    @Test
    fun `Error state carries error message`() {
        val state = WorkspaceUiState.Error("Connection refused")
        assertEquals("Connection refused", (state as WorkspaceUiState.Error).message)
    }

    @Test
    fun `Loading state is distinct`() {
        val state: WorkspaceUiState = WorkspaceUiState.Loading
        assertTrue(state is WorkspaceUiState.Loading)
    }
}
