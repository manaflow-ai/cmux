package dev.cmux.android.core.ghosttyvt

import java.io.ByteArrayOutputStream
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Wire shapes for the Mac's `terminal.render_grid` frames (format
 * "cmux.render-grid.v1"). Field names/wire keys mirror
 * MobileTerminalRenderGridFrame+Coding.swift / +Style.swift exactly. */
@Serializable
data class RenderGridStyle(
    val id: Int,
    val foreground: String? = null,
    val background: String? = null,
    @SerialName("foreground_source") val foregroundSource: String? = null,
    @SerialName("foreground_palette_index") val foregroundPaletteIndex: Int? = null,
    @SerialName("background_source") val backgroundSource: String? = null,
    @SerialName("background_palette_index") val backgroundPaletteIndex: Int? = null,
    val bold: Boolean = false,
    val faint: Boolean = false,
    val italic: Boolean = false,
    val underline: Boolean = false,
    val blink: Boolean = false,
    val inverse: Boolean = false,
    val invisible: Boolean = false,
    val strikethrough: Boolean = false,
    val overline: Boolean = false,
) {
    companion object {
        val DEFAULT = RenderGridStyle(id = 0)
    }
}

@Serializable
data class RenderGridRowSpan(
    val row: Int,
    val column: Int,
    @SerialName("style_id") val styleID: Int = 0,
    val text: String,
    @SerialName("cell_width") val cellWidth: Int? = null,
) {
    /** Approximation of the Swift side's grapheme-cluster cell width — wide-char
     * (CJK/emoji) column pinning is explicitly deferred for this MVP, so this
     * just falls back to UTF-16 code-unit count when the server omits it. */
    val gridCellWidth: Int get() = cellWidth ?: text.length
}

@Serializable
data class RenderGridCursor(
    val row: Int,
    val column: Int,
    val visible: Boolean = true,
    val style: String = "block",
    val blinking: Boolean = false,
)

@Serializable
data class RenderGridFrame(
    val columns: Int,
    val rows: Int,
    val cursor: RenderGridCursor? = null,
    val full: Boolean = true,
    @SerialName("cleared_rows") val clearedRows: List<Int> = emptyList(),
    val styles: List<RenderGridStyle> = listOf(RenderGridStyle.DEFAULT),
    @SerialName("row_spans") val rowSpans: List<RenderGridRowSpan> = emptyList(),
    @SerialName("active_screen") val activeScreen: String = "primary",
    @SerialName("scrolled_rows") val scrolledRows: Int = 0,
    @SerialName("scrollback_rows") val scrollbackRows: Int = 0,
    @SerialName("scrollback_spans") val scrollbackSpans: List<RenderGridRowSpan> = emptyList(),
)

/**
 * Kotlin port of iOS's `MobileTerminalRenderGridReplay` — synthesizes VT/ANSI
 * escape-sequence bytes that reproduce a render_grid frame, for feeding into
 * a real [GhosttyTerminal] via [GhosttyTerminal.write] (libghostty-vt has no
 * structured cell-setter API; VT bytes are the only mutation path).
 *
 * MVP scope: full/delta repaint with SGR styling only. Deliberately deferred
 * (see the implementation plan): alternate-screen scrollback-flow, wide-char
 * column pinning, hyperlink/OSC-133 semantic-prompt bytes, DEC mode-bank
 * restore, palette restore. Each of those matters for full TUI fidelity
 * (vim, htop) but not for correctly showing a shell prompt's text/colors/cursor.
 */
object RenderGridVtSynthesizer {

    /** The escape byte (0x1B). Every CSI sequence below is built by explicit
     * concatenation with this constant — there is no implicit ESC-prefixing
     * anywhere in this file, so every raw "[...]" string below is deliberate. */
    private const val ESC = '\u001B'

    fun patchBytes(frame: RenderGridFrame): ByteArray {
        val out = ByteArrayOutputStream()
        val stylesByID = frame.styles.associateBy { it.id }
        val defaultStyle = stylesByID[0] ?: RenderGridStyle.DEFAULT

        if (frame.full) {
            out.appendAscii("$ESC[H")
            for (row in 0 until frame.rows) {
                out.appendSgr(defaultStyle)
                out.appendAscii("$ESC[${row + 1};1H$ESC[2K")
            }
        } else {
            // Without this, a scrolling terminal (rows shifting up as new output
            // arrives at the bottom) only ever gets CUP-addressed rewrites of the
            // same absolute row positions — real content, but libghostty-vt never
            // sees an actual line feed, so nothing it can put in scrollback. This
            // replays the rows the Mac's own terminal pushed into its history
            // (scrollbackSpans, for a burst that outran one frame) then feeds a
            // plain "\r\n" per remaining push so our terminal scrolls the exact
            // same amount the Mac's did, growing real, later-scrollable history.
            appendDeltaScrollPrologue(out, frame, stylesByID, defaultStyle)
            val rowsToClear = (frame.clearedRows + frame.rowSpans.map { it.row }).distinct().sorted()
            for (row in rowsToClear) {
                out.appendSgr(defaultStyle)
                out.appendAscii("$ESC[${row + 1};1H$ESC[2K")
            }
        }

        paintSpans(out, frame.rowSpans, stylesByID)
        out.appendSgr(defaultStyle)
        appendCursorRestore(out, frame.cursor)
        return out.toByteArray()
    }

    /**
     * Scrolls the consumer's grid for a screen-anchored delta before row repaints:
     * a plain "\r\n" at the bottom row pushes the top row into scrollback, exactly
     * like a real terminal, so scrollback accumulates identically to the producer's
     * — same technique as iOS's `appendDeltaScrollPrologue`. A burst delta (more
     * rows scrolled than this one frame captured) additionally flows the missed
     * history rows through first, oldest first, so nothing is silently skipped.
     */
    private fun appendDeltaScrollPrologue(
        out: ByteArrayOutputStream,
        frame: RenderGridFrame,
        stylesByID: Map<Int, RenderGridStyle>,
        defaultStyle: RenderGridStyle,
    ) {
        val pushes = frame.scrolledRows
        if (pushes <= 0 || frame.activeScreen != "primary") return
        val missed = minOf(maxOf(0, frame.scrollbackRows), pushes)

        out.appendSgr(defaultStyle)
        out.appendAscii("$ESC[r$ESC[${frame.rows};1H")

        if (missed > 0) {
            out.appendAscii("\r\n")
            appendFlowLines(out, frame.scrollbackSpans, missed, frame.columns, stylesByID, defaultStyle, terminateLast = false)
        }
        val trailing = pushes - missed
        if (trailing > 0) {
            out.appendSgr(defaultStyle)
            repeat(trailing) { out.appendAscii("\r\n") }
        }
    }

    /** Replays `lineCount` lines of `spans` (rows 0..<lineCount) as a natural
     * scrolling flow: each line resets to the default style, positions its spans
     * with CHA (cursor-horizontal-absolute), and is separated from the next by
     * CRLF — so, unlike [paintSpans]' absolute CUP addressing, this genuinely
     * scrolls the terminal and grows real scrollback. */
    private fun appendFlowLines(
        out: ByteArrayOutputStream,
        spans: List<RenderGridRowSpan>,
        lineCount: Int,
        columns: Int,
        stylesByID: Map<Int, RenderGridStyle>,
        defaultStyle: RenderGridStyle,
        terminateLast: Boolean,
    ) {
        if (lineCount <= 0) return
        val spansByRow = spans.groupBy { it.row }
        for (line in 0 until lineCount) {
            if (line > 0) out.appendAscii("\r\n")
            out.appendSgr(defaultStyle)
            var activeStyleID: Int? = 0
            var paintedEnd = 0
            for (span in (spansByRow[line] ?: emptyList()).sortedBy { it.column }) {
                if (span.text.isEmpty()) continue
                if (span.column > paintedEnd) {
                    if (activeStyleID != 0) out.appendSgr(defaultStyle)
                    activeStyleID = 0
                    out.appendAscii("$ESC[${paintedEnd + 1}G")
                    out.appendVtPrintable(" ".repeat(span.column - paintedEnd))
                    paintedEnd = span.column
                }
                if (activeStyleID != span.styleID) {
                    val style = stylesByID[span.styleID]
                    if (style != null) {
                        out.appendSgr(style)
                        activeStyleID = span.styleID
                    }
                }
                out.appendVtPrintable(span.text)
                paintedEnd = maxOf(paintedEnd, span.column + span.gridCellWidth)
            }
            if (paintedEnd < columns) {
                if (activeStyleID != 0) out.appendSgr(defaultStyle)
                out.appendAscii("$ESC[${paintedEnd + 1}G")
                out.appendVtPrintable(" ".repeat(columns - paintedEnd))
            }
        }
        if (terminateLast) out.appendAscii("\r\n")
    }

    private fun paintSpans(
        out: ByteArrayOutputStream,
        spans: List<RenderGridRowSpan>,
        stylesByID: Map<Int, RenderGridStyle>,
    ) {
        var activeStyleID: Int? = null
        for (span in spans) {
            if (span.text.isEmpty()) continue
            out.appendAscii("$ESC[${span.row + 1};${span.column + 1}H")
            if (activeStyleID != span.styleID) {
                val style = stylesByID[span.styleID]
                if (style != null) {
                    out.appendSgr(style)
                    activeStyleID = span.styleID
                }
            }
            out.appendVtPrintable(span.text)
        }
    }

    private fun appendCursorRestore(out: ByteArrayOutputStream, cursor: RenderGridCursor?) {
        if (cursor == null) {
            out.appendAscii("$ESC[?25h")
            return
        }
        out.appendAscii(cursorStyleBytes(cursor))
        val positioning = "$ESC[${cursor.row + 1};${cursor.column + 1}H"
        out.appendAscii(if (cursor.visible) "$ESC[?25h$positioning" else "$ESC[?25l$positioning")
    }

    private fun cursorStyleBytes(cursor: RenderGridCursor): String {
        val parameter = when (cursor.style) {
            "block", "block_hollow" -> if (cursor.blinking) 1 else 2
            "underline" -> if (cursor.blinking) 3 else 4
            "bar" -> if (cursor.blinking) 5 else 6
            else -> if (cursor.blinking) 1 else 2
        }
        return "$ESC[$parameter q"
    }

    private fun ByteArrayOutputStream.appendAscii(s: String) {
        write(s.toByteArray(Charsets.US_ASCII))
    }

    private fun ByteArrayOutputStream.appendVtPrintable(text: String) {
        for (codePoint in text.codePoints().toArray()) {
            if (codePoint in 0x20..0x7E || codePoint >= 0xA0) {
                write(String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8))
            } else {
                write(' '.code)
            }
        }
    }

    private fun ByteArrayOutputStream.appendSgr(style: RenderGridStyle) {
        val codes = mutableListOf("0")
        if (style.bold) codes.add("1")
        if (style.faint) codes.add("2")
        if (style.italic) codes.add("3")
        if (style.underline) codes.add("4")
        if (style.blink) codes.add("5")
        if (style.inverse) codes.add("7")
        if (style.invisible) codes.add("8")
        if (style.strikethrough) codes.add("9")
        if (style.overline) codes.add("53")

        when {
            style.foregroundSource == "default" -> codes.add("39")
            style.foregroundSource == "palette" && style.foregroundPaletteIndex in 0..255 ->
                codes.add("38;5;${style.foregroundPaletteIndex}")
            else -> rgbComponents(style.foreground)?.let { (r, g, b) -> codes.add("38;2;$r;$g;$b") }
        }
        when {
            style.backgroundSource == "default" -> codes.add("49")
            style.backgroundSource == "palette" && style.backgroundPaletteIndex in 0..255 ->
                codes.add("48;5;${style.backgroundPaletteIndex}")
            else -> rgbComponents(style.background)?.let { (r, g, b) -> codes.add("48;2;$r;$g;$b") }
        }

        appendAscii("$ESC[${codes.joinToString(";")}m")
    }

    private fun rgbComponents(hex: String?): Triple<Int, Int, Int>? {
        if (hex == null) return null
        val value = hex.removePrefix("#")
        if (value.length != 6) return null
        val raw = value.toIntOrNull(16) ?: return null
        return Triple((raw shr 16) and 0xFF, (raw shr 8) and 0xFF, raw and 0xFF)
    }
}
