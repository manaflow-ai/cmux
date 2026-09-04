package dev.cmux.termux

/**
 * Minimal VT100/ANSI terminal emulator for the cmux Android demo.
 *
 * This is a simplified stand-in for the full Termux terminal-emulator library.
 * For production, vendor the full Termux terminal-emulator Gradle module from
 * https://github.com/termux/termux-app/tree/master/terminal-emulator and replace
 * this class with TerminalSession + TerminalEmulator from that library.
 *
 * The interface here mirrors Termux's TerminalEmulator API so the feature module
 * can call `emulator.feed(bytes)` and `emulator.screen` identically.
 */
class TerminalEmulator(
    var columns: Int = 80,
    var rows: Int = 24,
) {
    /** Flat array of characters on screen (rows * columns). */
    private val cells = Array(rows) { CharArray(columns) { ' ' } }

    private var cursorRow = 0
    private var cursorCol = 0
    private val pendingEscape = StringBuilder()
    private var inEscape = false

    /** Listeners receive a callback whenever screen state changes. */
    var onChange: (() -> Unit)? = null

    /**
     * Feed raw bytes from the terminal output stream into the emulator.
     * Handles basic ANSI escape sequences (cursor movement, clear screen, SGR).
     */
    fun feed(data: ByteArray) {
        for (byte in data) {
            val ch = byte.toInt().and(0xFF).toChar()
            processChar(ch)
        }
        onChange?.invoke()
    }

    /** Return the current screen as a list of strings (one per row). */
    val screen: List<String>
        get() = cells.map { String(it) }

    /** Return raw text content (for testing). */
    fun screenText(): String = screen.joinToString("\n")

    fun resize(columns: Int, rows: Int) {
        this.columns = columns
        this.rows = rows
        // Re-init cells; real implementation would reflow
    }

    private fun processChar(ch: Char) {
        when {
            inEscape -> handleEscape(ch)
            ch == '\u001B' -> {
                inEscape = true
                pendingEscape.clear()
                pendingEscape.append(ch)
            }
            ch == '\n' -> {
                cursorCol = 0
                if (cursorRow < rows - 1) cursorRow++ else scrollUp()
            }
            ch == '\r' -> cursorCol = 0
            ch == '\b' -> cursorCol = (cursorCol - 1).coerceAtLeast(0)
            ch >= ' ' -> {
                if (cursorRow < rows && cursorCol < columns) {
                    cells[cursorRow][cursorCol] = ch
                    cursorCol++
                    if (cursorCol >= columns) {
                        cursorCol = 0
                        cursorRow = (cursorRow + 1).coerceAtMost(rows - 1)
                    }
                }
            }
        }
    }

    private fun handleEscape(ch: Char) {
        pendingEscape.append(ch)
        val seq = pendingEscape.toString()
        when {
            seq == "\u001B[2J" || seq == "\u001B[3J" -> { clearScreen(); inEscape = false }
            seq == "\u001Bc" || seq == "\u001B[H\u001B[2J" -> { clearScreen(); inEscape = false }
            seq.matches(Regex("\u001B\\[\\d*;?\\d*H")) -> {
                // Cursor position: ESC[row;colH
                val parts = seq.removePrefix("\u001B[").removeSuffix("H").split(";")
                cursorRow = ((parts.getOrNull(0)?.toIntOrNull() ?: 1) - 1).coerceAtLeast(0).coerceAtMost(rows - 1)
                cursorCol = ((parts.getOrNull(1)?.toIntOrNull() ?: 1) - 1).coerceAtLeast(0).coerceAtMost(columns - 1)
                inEscape = false
            }
            // SGR (colors/attributes), cursor movement, erase — all ignored for demo
            seq.matches(Regex("\u001B\\[\\d*(;\\d+)*m")) -> { inEscape = false }
            seq.matches(Regex("\u001B\\[\\d*[ABCDK]")) -> {
                // Cursor up/down/forward/back/erase-to-end-of-line
                val n = seq.removePrefix("\u001B[").dropLast(1).toIntOrNull() ?: 1
                when (seq.last()) {
                    'A' -> cursorRow = (cursorRow - n).coerceAtLeast(0)
                    'B' -> cursorRow = (cursorRow + n).coerceAtMost(rows - 1)
                    'C' -> cursorCol = (cursorCol + n).coerceAtMost(columns - 1)
                    'D' -> cursorCol = (cursorCol - n).coerceAtLeast(0)
                    'K' -> { for (c in cursorCol until columns) cells[cursorRow][c] = ' ' }
                }
                inEscape = false
            }
            // OSC sequences: ESC ] ... BEL or ESC ] ... ESC backslash
            seq.length >= 3 && seq[1] == ']' && (ch == '\u0007' || (seq.length >= 4 && seq[seq.length - 2] == '\u001B' && ch == '\\')) -> {
                inEscape = false
            }
            // DEC private modes and other ? sequences — ignore
            seq.matches(Regex("\u001B\\[\\?[\\d;]+[hlr]")) -> { inEscape = false }
            // Bail on overlong sequences that didn't match anything
            seq.length > 64 -> inEscape = false
        }
    }

    private fun clearScreen() {
        for (row in cells) row.fill(' ')
        cursorRow = 0
        cursorCol = 0
    }

    private fun scrollUp() {
        for (i in 0 until rows - 1) cells[i] = cells[i + 1].copyOf()
        cells[rows - 1].fill(' ')
    }
}
