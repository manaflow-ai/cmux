package dev.cmux.android.feature.terminal

import dev.cmux.termux.TerminalEmulator
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

/**
 * Unit tests for TerminalViewModel event routing.
 *
 * Tests validate that bytes fed through the emulator update screen state correctly.
 * Network and ViewModel integration is validated on the emulator.
 */
class TerminalViewModelTest {

    @Test
    fun `TerminalEmulator feed updates screen lines`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        emulator.feed("hello".toByteArray())
        val screen = emulator.screen
        assertEquals(5, screen.size)
        assertTrue(screen[0].startsWith("hello"))
    }

    @Test
    fun `TerminalEmulator clears screen on clear sequence`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        emulator.feed("text".toByteArray())
        emulator.feed("\u001B[2J".toByteArray())
        val text = emulator.screenText()
        assertFalse(text.contains("text"))
    }

    @Test
    fun `TerminalEmulator handles newline correctly`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        emulator.feed("line1\nline2".toByteArray())
        val screen = emulator.screen
        assertTrue(screen[0].startsWith("line1"))
        assertTrue(screen[1].startsWith("line2"))
    }

    @Test
    fun `TerminalEmulator onChange callback fires on feed`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        var callCount = 0
        emulator.onChange = { callCount++ }
        emulator.feed("test".toByteArray())
        assertEquals(1, callCount)
    }

    @Test
    fun `TerminalEmulator handles carriage return`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        // "overwrite" is written, then CR moves cursor back to column 0, then "---" overwrites first 3 chars
        emulator.feed("overwrite\r---".toByteArray())
        val line = emulator.screen[0]
        assertTrue(line.startsWith("---"))
    }

    @Test
    fun `TerminalUiState Connected holds correct lines`() {
        val lines = listOf("line 1", "line 2", "line 3")
        val state: TerminalUiState = TerminalUiState.Connected(lines)
        assertTrue(state is TerminalUiState.Connected)
        assertEquals(3, (state as TerminalUiState.Connected).lines.size)
        assertEquals("line 2", state.lines[1])
    }

    @Test
    fun `terminal bytes event base64 payload decodes to screen output`() {
        val emulator = TerminalEmulator(columns = 80, rows = 5)
        val text = "hello from server"
        val b64 = java.util.Base64.getEncoder().encodeToString(text.toByteArray())
        val bytes = java.util.Base64.getDecoder().decode(b64)
        emulator.feed(bytes)
        assertTrue(emulator.screen[0].startsWith("hello from server"))
    }
}
