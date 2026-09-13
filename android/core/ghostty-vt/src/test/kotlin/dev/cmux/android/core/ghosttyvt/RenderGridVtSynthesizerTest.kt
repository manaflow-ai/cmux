package dev.cmux.android.core.ghosttyvt

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

private const val ESC = '\u001B'

class RenderGridVtSynthesizerTest {

    @Test
    fun `full snapshot bytes start with a real ESC byte, not a literal bracket`() {
        val frame = RenderGridFrame(columns = 10, rows = 2, full = true, rowSpans = emptyList())
        val bytes = RenderGridVtSynthesizer.patchBytes(frame)
        assertTrue(bytes.isNotEmpty())
        assertEquals(0x1B, bytes[0].toInt() and 0xFF)
    }

    @Test
    fun `full snapshot clears every row and repositions cursor home`() {
        val frame = RenderGridFrame(columns = 10, rows = 3, full = true, rowSpans = emptyList())
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(text.startsWith("$ESC[H"))
        for (row in 1..3) {
            assertTrue(text.contains("$ESC[$row;1H$ESC[2K"), "expected clear for row $row in: $text")
        }
    }

    @Test
    fun `span text is positioned and painted with the escape byte present`() {
        val span = RenderGridRowSpan(row = 0, column = 2, styleID = 0, text = "hi")
        val frame = RenderGridFrame(columns = 10, rows = 1, full = true, rowSpans = listOf(span))
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        // Style 0 (default) always differs from paintSpans' initial null
        // activeStyleID, so an SGR reset is emitted between positioning and text.
        assertTrue(text.contains("$ESC[1;3H$ESC[0mhi"), "expected positioned+styled span text in: $text")
    }

    @Test
    fun `delta only clears cleared_rows union changed span rows`() {
        val frame = RenderGridFrame(
            columns = 10,
            rows = 5,
            full = false,
            clearedRows = listOf(1),
            rowSpans = listOf(RenderGridRowSpan(row = 3, column = 0, text = "x")),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(text.contains("$ESC[2;1H$ESC[2K"), "row 1 (0-indexed) should be cleared: $text")
        assertTrue(text.contains("$ESC[4;1H$ESC[2K"), "row 3 (0-indexed) should be cleared: $text")
        assertTrue(!text.contains("$ESC[1;1H$ESC[2K"), "row 0 should NOT be cleared: $text")
    }

    @Test
    fun `SGR encodes bold and 24-bit rgb foreground`() {
        val style = RenderGridStyle(id = 1, foreground = "#ff0080", bold = true)
        val frame = RenderGridFrame(
            columns = 10,
            rows = 1,
            full = true,
            styles = listOf(RenderGridStyle.DEFAULT, style),
            rowSpans = listOf(RenderGridRowSpan(row = 0, column = 0, styleID = 1, text = "x")),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(text.contains("${ESC}[0;1;38;2;255;0;128m"), "expected bold+rgb SGR in: $text")
    }

    @Test
    fun `cursor restore positions and shows the cursor when visible`() {
        val frame = RenderGridFrame(
            columns = 10,
            rows = 5,
            full = true,
            cursor = RenderGridCursor(row = 2, column = 4, visible = true, style = "bar", blinking = false),
            rowSpans = emptyList(),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(text.endsWith("${ESC}[6 q${ESC}[?25h${ESC}[3;5H"), "expected trailing cursor restore in: $text")
    }

    @Test
    fun `delta frame with scrolled_rows emits natural line feeds before clearing`() {
        val frame = RenderGridFrame(
            columns = 10,
            rows = 5,
            full = false,
            scrolledRows = 2,
            scrollbackRows = 0,
            rowSpans = listOf(RenderGridRowSpan(row = 4, column = 0, text = "new")),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        // Two pushed rows with nothing yet in scrollback (missed=0) should still
        // advance the cursor by two bare newlines from the bottom row (after the
        // trailing SGR reset), before any row-clearing escapes for the delta repaint.
        assertTrue(
            text.contains("$ESC[5;1H$ESC[0m\r\n\r\n"),
            "expected two bare newlines right after the bottom-row CUP in: $text",
        )
    }

    @Test
    fun `delta frame with scrolled_rows and scrollback flows scrollback lines through`() {
        val scrollbackSpan = RenderGridRowSpan(row = 0, column = 0, text = "older line")
        val frame = RenderGridFrame(
            columns = 10,
            rows = 5,
            full = false,
            scrolledRows = 1,
            scrollbackRows = 1,
            scrollbackSpans = listOf(scrollbackSpan),
            rowSpans = listOf(RenderGridRowSpan(row = 4, column = 0, text = "new")),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(text.contains("older line"), "expected scrollback line flowed into output: $text")
    }

    @Test
    fun `delta frame with zero scrolled_rows emits no scroll prologue`() {
        val frame = RenderGridFrame(
            columns = 10,
            rows = 5,
            full = false,
            scrolledRows = 0,
            clearedRows = listOf(2),
        )
        val text = String(RenderGridVtSynthesizer.patchBytes(frame), Charsets.US_ASCII)

        assertTrue(!text.contains("\r\n"), "expected no natural newlines when scrolledRows=0: $text")
    }

    @Test
    fun `non-ASCII printable characters are UTF-8 encoded, not dropped`() {
        val span = RenderGridRowSpan(row = 0, column = 0, text = "café")
        val frame = RenderGridFrame(columns = 10, rows = 1, full = true, rowSpans = listOf(span))
        val bytes = RenderGridVtSynthesizer.patchBytes(frame)
        val text = String(bytes, Charsets.UTF_8)

        assertTrue(text.contains("café"), "expected UTF-8 'café' preserved in: $text")
    }
}
