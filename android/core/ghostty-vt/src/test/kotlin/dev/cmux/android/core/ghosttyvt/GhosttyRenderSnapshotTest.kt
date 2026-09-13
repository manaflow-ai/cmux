package dev.cmux.android.core.ghosttyvt

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Verifies GhosttyRenderSnapshot.decode() against a hand-built buffer matching
 * the layout ghostty_vt_jni.cpp's nativeSnapshot() writes — this is pure JVM
 * logic, so it doesn't need the native .so or an Android device/emulator.
 */
class GhosttyRenderSnapshotTest {

    private fun buildFrame(
        cols: Int,
        rows: Int,
        cursorVisible: Boolean,
        cursorX: Int,
        cursorY: Int,
        cursorVisualStyle: Int,
        cursorBlinking: Boolean,
        defaultFg: Triple<Int, Int, Int>,
        defaultBg: Triple<Int, Int, Int>,
        cellFor: (row: Int, col: Int) -> ByteArray,
    ): ByteArray {
        val header = ByteBuffer.allocate(25).order(ByteOrder.LITTLE_ENDIAN)
        header.putInt(cols)
        header.putInt(rows)
        header.put(if (cursorVisible) 1 else 0)
        header.putInt(cursorX)
        header.putInt(cursorY)
        header.put(cursorVisualStyle.toByte())
        header.put(if (cursorBlinking) 1 else 0)
        header.put(defaultFg.first.toByte())
        header.put(defaultFg.second.toByte())
        header.put(defaultFg.third.toByte())
        header.put(defaultBg.first.toByte())
        header.put(defaultBg.second.toByte())
        header.put(defaultBg.third.toByte())

        val out = java.io.ByteArrayOutputStream()
        out.write(header.array())
        for (row in 0 until rows) {
            for (col in 0 until cols) {
                out.write(cellFor(row, col))
            }
        }
        return out.toByteArray()
    }

    private fun cellBytes(
        codepoint: Int,
        hasFg: Boolean = false,
        fg: Triple<Int, Int, Int> = Triple(0, 0, 0),
        hasBg: Boolean = false,
        bg: Triple<Int, Int, Int> = Triple(0, 0, 0),
        flags: Int = 0,
        underlineStyle: Int = 0,
    ): ByteArray {
        val buf = ByteBuffer.allocate(14).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(codepoint)
        buf.put(if (hasFg) 1 else 0)
        buf.put(fg.first.toByte()); buf.put(fg.second.toByte()); buf.put(fg.third.toByte())
        buf.put(if (hasBg) 1 else 0)
        buf.put(bg.first.toByte()); buf.put(bg.second.toByte()); buf.put(bg.third.toByte())
        buf.put(flags.toByte())
        buf.put(underlineStyle.toByte())
        return buf.array()
    }

    @Test
    fun `decodes header fields correctly`() {
        val bytes = buildFrame(
            cols = 2, rows = 1,
            cursorVisible = true, cursorX = 1, cursorY = 0,
            cursorVisualStyle = 1, cursorBlinking = true,
            defaultFg = Triple(212, 212, 212), defaultBg = Triple(13, 13, 13),
        ) { _, _ -> cellBytes(codepoint = 'x'.code) }

        val snapshot = GhosttyRenderSnapshot.decode(bytes)

        assertEquals(2, snapshot.columns)
        assertEquals(1, snapshot.rows)
        assertTrue(snapshot.cursorVisible)
        assertEquals(1, snapshot.cursorX)
        assertEquals(0, snapshot.cursorY)
        assertEquals(GhosttyCursorVisualStyle.BLOCK, snapshot.cursorVisualStyle)
        assertTrue(snapshot.cursorBlinking)
        assertEquals(Triple(212, 212, 212), snapshot.defaultForeground)
        assertEquals(Triple(13, 13, 13), snapshot.defaultBackground)
    }

    @Test
    fun `decodes cell text and colors`() {
        val bytes = buildFrame(
            cols = 1, rows = 1,
            cursorVisible = false, cursorX = 0, cursorY = 0,
            cursorVisualStyle = 0, cursorBlinking = false,
            defaultFg = Triple(0, 0, 0), defaultBg = Triple(0, 0, 0),
        ) { _, _ ->
            cellBytes(
                codepoint = 'A'.code,
                hasFg = true, fg = Triple(255, 0, 0),
                hasBg = true, bg = Triple(0, 255, 0),
            )
        }

        val cell = GhosttyRenderSnapshot.decode(bytes).rowData[0].cells[0]

        assertEquals('A'.code, cell.codepoint)
        assertTrue(cell.hasFg)
        assertEquals(255, cell.fgR)
        assertTrue(cell.hasBg)
        assertEquals(255, cell.bgG)
    }

    @Test
    fun `decodes style flag bitmask`() {
        val boldItalicUnderline = 0x01 or 0x02
        val bytes = buildFrame(
            cols = 1, rows = 1,
            cursorVisible = false, cursorX = 0, cursorY = 0,
            cursorVisualStyle = 0, cursorBlinking = false,
            defaultFg = Triple(0, 0, 0), defaultBg = Triple(0, 0, 0),
        ) { _, _ -> cellBytes(codepoint = 'B'.code, flags = boldItalicUnderline, underlineStyle = 1) }

        val cell = GhosttyRenderSnapshot.decode(bytes).rowData[0].cells[0]

        assertTrue(cell.bold)
        assertTrue(cell.italic)
        assertFalse(cell.faint)
        assertFalse(cell.inverse)
        assertEquals(1, cell.underlineStyle)
    }

    @Test
    fun `decodes multiple rows and columns in order`() {
        val bytes = buildFrame(
            cols = 2, rows = 2,
            cursorVisible = false, cursorX = 0, cursorY = 0,
            cursorVisualStyle = 0, cursorBlinking = false,
            defaultFg = Triple(0, 0, 0), defaultBg = Triple(0, 0, 0),
        ) { row, col -> cellBytes(codepoint = ('0'.code + row * 2 + col)) }

        val snapshot = GhosttyRenderSnapshot.decode(bytes)

        assertEquals(2, snapshot.rowData.size)
        assertEquals('0'.code, snapshot.rowData[0].cells[0].codepoint)
        assertEquals('1'.code, snapshot.rowData[0].cells[1].codepoint)
        assertEquals('2'.code, snapshot.rowData[1].cells[0].codepoint)
        assertEquals('3'.code, snapshot.rowData[1].cells[1].codepoint)
    }
}
