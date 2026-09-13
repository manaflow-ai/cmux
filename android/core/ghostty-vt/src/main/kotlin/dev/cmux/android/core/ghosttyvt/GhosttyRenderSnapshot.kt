package dev.cmux.android.core.ghosttyvt

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One terminal cell's paintable state, resolved by libghostty-vt (colors already
 * flattened from palette/RGB/style sources — see GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_*
 * in ghostty/include/ghostty/vt/render.h). Combining/grapheme codepoints beyond the
 * base one are dropped for this MVP. */
data class GhosttyCell(
    val codepoint: Int,
    val hasFg: Boolean,
    val fgR: Int,
    val fgG: Int,
    val fgB: Int,
    val hasBg: Boolean,
    val bgR: Int,
    val bgG: Int,
    val bgB: Int,
    val bold: Boolean,
    val italic: Boolean,
    val faint: Boolean,
    val blink: Boolean,
    val inverse: Boolean,
    val invisible: Boolean,
    val strikethrough: Boolean,
    val overline: Boolean,
    /** One of GHOSTTY_SGR_UNDERLINE_* — 0 means no underline. */
    val underlineStyle: Int,
)

data class GhosttyRow(val cells: List<GhosttyCell>)

enum class GhosttyCursorVisualStyle { BAR, BLOCK, UNDERLINE, BLOCK_HOLLOW }

/** A fully decoded, paintable terminal frame — one call to [GhosttyTerminal.snapshot]
 * per redraw. Mirrors the binary layout written by nativeSnapshot() in ghostty_vt_jni.cpp. */
data class GhosttyRenderSnapshot(
    val columns: Int,
    val rows: Int,
    val cursorVisible: Boolean,
    val cursorX: Int,
    val cursorY: Int,
    val cursorVisualStyle: GhosttyCursorVisualStyle,
    val cursorBlinking: Boolean,
    val defaultForeground: Triple<Int, Int, Int>,
    val defaultBackground: Triple<Int, Int, Int>,
    val rowData: List<GhosttyRow>,
) {
    companion object {
        fun decode(bytes: ByteArray): GhosttyRenderSnapshot {
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

            fun readRgb(): Triple<Int, Int, Int> {
                val r = buf.get().toInt() and 0xFF
                val g = buf.get().toInt() and 0xFF
                val b = buf.get().toInt() and 0xFF
                return Triple(r, g, b)
            }

            val cols = buf.int
            val rowsCount = buf.int
            val cursorVisible = buf.get().toInt() != 0
            val cursorX = buf.int
            val cursorY = buf.int
            val cursorVisualStyleRaw = buf.get().toInt() and 0xFF
            val cursorBlinking = buf.get().toInt() != 0
            val defaultFg = readRgb()
            val defaultBg = readRgb()

            val cursorVisualStyle = GhosttyCursorVisualStyle.entries
                .getOrElse(cursorVisualStyleRaw) { GhosttyCursorVisualStyle.BLOCK }

            val rowsList = ArrayList<GhosttyRow>(rowsCount)
            repeat(rowsCount) {
                val cells = ArrayList<GhosttyCell>(cols)
                repeat(cols) {
                    val codepoint = buf.int
                    val hasFg = buf.get().toInt() != 0
                    val (fgR, fgG, fgB) = readRgb()
                    val hasBg = buf.get().toInt() != 0
                    val (bgR, bgG, bgB) = readRgb()
                    val flags = buf.get().toInt() and 0xFF
                    val underlineStyle = buf.get().toInt() and 0xFF
                    cells.add(
                        GhosttyCell(
                            codepoint = codepoint,
                            hasFg = hasFg, fgR = fgR, fgG = fgG, fgB = fgB,
                            hasBg = hasBg, bgR = bgR, bgG = bgG, bgB = bgB,
                            bold = flags and 0x01 != 0,
                            italic = flags and 0x02 != 0,
                            faint = flags and 0x04 != 0,
                            blink = flags and 0x08 != 0,
                            inverse = flags and 0x10 != 0,
                            invisible = flags and 0x20 != 0,
                            strikethrough = flags and 0x40 != 0,
                            overline = flags and 0x80 != 0,
                            underlineStyle = underlineStyle,
                        ),
                    )
                }
                rowsList.add(GhosttyRow(cells))
            }

            return GhosttyRenderSnapshot(
                columns = cols,
                rows = rowsCount,
                cursorVisible = cursorVisible,
                cursorX = cursorX,
                cursorY = cursorY,
                cursorVisualStyle = cursorVisualStyle,
                cursorBlinking = cursorBlinking,
                defaultForeground = defaultFg,
                defaultBackground = defaultBg,
                rowData = rowsList,
            )
        }
    }
}
