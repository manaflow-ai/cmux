package dev.cmux.android.feature.terminal

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.sp
import dev.cmux.android.core.ghosttyvt.GhosttyCell
import dev.cmux.android.core.ghosttyvt.GhosttyCursorVisualStyle
import dev.cmux.android.core.ghosttyvt.GhosttyRenderSnapshot

private val TerminalFontSize = 13.sp

/**
 * Paints a [GhosttyRenderSnapshot] cell-by-cell with Compose's 2D Canvas —
 * real libghostty-vt terminal state (colors, cursor, box-drawing, attributes)
 * without a GPU-shader renderer (none exists for Android; see the plan's
 * rendering-approach decision). Repaints the full grid on every snapshot;
 * dirty-region partial redraws are a follow-up if this shows frame drops.
 *
 * A vertical drag scrolls the *terminal's own scrollback* via [onScroll]
 * (calling into [dev.cmux.android.core.ghosttyvt.GhosttyTerminal.scrollBy])
 * rather than a Compose scroll container: the content a taller-than-screen
 * terminal is missing usually isn't more of the current active-area render —
 * it's real history that already scrolled out of the active area entirely,
 * which only libghostty-vt's own viewport-scroll API can bring back into
 * the snapshot this composable draws.
 */
@Composable
fun TerminalCanvas(
    snapshot: GhosttyRenderSnapshot,
    modifier: Modifier = Modifier,
    onScroll: (rows: Int) -> Unit = {},
) {
    val textMeasurer = rememberTextMeasurer()
    val baseStyle = remember { TextStyle(fontFamily = FontFamily.Monospace, fontSize = TerminalFontSize) }
    val glyphSize = remember(textMeasurer, baseStyle) { textMeasurer.measure("M", baseStyle).size }
    val cellWidth = glyphSize.width.toFloat()
    val cellHeight = glyphSize.height.toFloat()

    val (fgR, fgG, fgB) = snapshot.defaultForeground
    val (bgR, bgG, bgB) = snapshot.defaultBackground
    val defaultFg = Color(fgR, fgG, fgB)
    val defaultBg = Color(bgR, bgG, bgB)

    Canvas(
        modifier = modifier
            .background(defaultBg)
            .pointerInput(cellHeight, onScroll) {
                // Accumulate sub-row drag distance so slow drags aren't lost to
                // per-event rounding; only emit whole-row scroll steps.
                var accumulatedPx = 0f
                detectVerticalDragGestures { change, dragAmount ->
                    change.consume()
                    accumulatedPx += dragAmount
                    val rows = (accumulatedPx / cellHeight).toInt()
                    if (rows != 0) {
                        // Dragging down (positive dragAmount) reveals earlier/older
                        // content, i.e. scrolls up — and the native API's "up" is
                        // negative — so this is inverted from the raw drag sign.
                        onScroll(-rows)
                        accumulatedPx -= rows * cellHeight
                    }
                }
            },
    ) {
        snapshot.rowData.forEachIndexed { rowIndex, row ->
            row.cells.forEachIndexed { colIndex, cell ->
                drawCell(
                    cell = cell,
                    x = colIndex * cellWidth,
                    y = rowIndex * cellHeight,
                    cellWidth = cellWidth,
                    cellHeight = cellHeight,
                    defaultFg = defaultFg,
                    defaultBg = defaultBg,
                    textMeasurer = textMeasurer,
                    baseStyle = baseStyle,
                )
            }
        }

        if (snapshot.cursorVisible) {
            drawCursor(snapshot = snapshot, cellWidth = cellWidth, cellHeight = cellHeight, color = defaultFg)
        }
    }
}

private fun DrawScope.drawCell(
    cell: GhosttyCell,
    x: Float,
    y: Float,
    cellWidth: Float,
    cellHeight: Float,
    defaultFg: Color,
    defaultBg: Color,
    textMeasurer: TextMeasurer,
    baseStyle: TextStyle,
) {
    var fg = if (cell.hasFg) Color(cell.fgR, cell.fgG, cell.fgB) else defaultFg
    var bg = if (cell.hasBg) Color(cell.bgR, cell.bgG, cell.bgB) else defaultBg
    if (cell.inverse) {
        val swap = fg
        fg = bg
        bg = swap
    }

    drawRect(color = bg, topLeft = Offset(x, y), size = Size(cellWidth, cellHeight))

    if (cell.codepoint == 0 || cell.codepoint == ' '.code || cell.invisible) return

    val decoration = when {
        cell.underlineStyle != 0 && cell.strikethrough ->
            TextDecoration.combine(listOf(TextDecoration.Underline, TextDecoration.LineThrough))
        cell.underlineStyle != 0 -> TextDecoration.Underline
        cell.strikethrough -> TextDecoration.LineThrough
        else -> null
    }

    val style = baseStyle.copy(
        color = if (cell.faint) fg.copy(alpha = 0.6f) else fg,
        fontWeight = if (cell.bold) FontWeight.Bold else FontWeight.Normal,
        fontStyle = if (cell.italic) FontStyle.Italic else FontStyle.Normal,
        textDecoration = decoration,
    )
    // An explicit per-cell size is required here: drawText's default (Size.Unspecified)
    // lays the text out within "canvas size minus topLeft", which goes negative — and
    // crashes with IllegalArgumentException — for any cell whose x/y falls at or past
    // the Canvas's actual bounds. That's routine here: the terminal's column/row count
    // comes from libghostty-vt and can exceed what fits on screen at this font size.
    drawText(
        textMeasurer,
        String(Character.toChars(cell.codepoint)),
        topLeft = Offset(x, y),
        style = style,
        size = Size(cellWidth, cellHeight),
    )

    if (cell.overline) {
        drawLine(color = fg, start = Offset(x, y), end = Offset(x + cellWidth, y), strokeWidth = 1f)
    }
}

private fun DrawScope.drawCursor(
    snapshot: GhosttyRenderSnapshot,
    cellWidth: Float,
    cellHeight: Float,
    color: Color,
) {
    val x = snapshot.cursorX * cellWidth
    val y = snapshot.cursorY * cellHeight
    when (snapshot.cursorVisualStyle) {
        GhosttyCursorVisualStyle.BLOCK -> drawRect(
            color = color.copy(alpha = 0.5f),
            topLeft = Offset(x, y),
            size = Size(cellWidth, cellHeight),
        )
        GhosttyCursorVisualStyle.BLOCK_HOLLOW -> drawRect(
            color = color,
            topLeft = Offset(x, y),
            size = Size(cellWidth, cellHeight),
            style = Stroke(width = 1f),
        )
        GhosttyCursorVisualStyle.BAR -> drawLine(
            color = color,
            start = Offset(x, y),
            end = Offset(x, y + cellHeight),
            strokeWidth = 2f,
        )
        GhosttyCursorVisualStyle.UNDERLINE -> drawLine(
            color = color,
            start = Offset(x, y + cellHeight),
            end = Offset(x + cellWidth, y + cellHeight),
            strokeWidth = 2f,
        )
    }
}
