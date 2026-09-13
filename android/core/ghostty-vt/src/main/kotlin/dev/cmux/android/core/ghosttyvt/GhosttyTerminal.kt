package dev.cmux.android.core.ghosttyvt

/**
 * A libghostty-vt terminal instance plus its render-state — the real Ghostty
 * VT parser (headless, no GPU rendering), reached via JNI. Feed it VT/ANSI
 * bytes with [write] (the only mutation path the C API exposes), then call
 * [snapshot] to pull a paintable frame (rows/cells/style/cursor) for a
 * Compose Canvas to draw.
 *
 * Owned by a ViewModel (not a Composable) so its native memory outlives
 * recomposition; call [close] exactly once, from onCleared().
 *
 * Thread-safety: callers reach this from at least two threads — the RPC
 * event-collection coroutine (background, calling [write] whenever new
 * content arrives) and the UI thread (calling [scrollBy]/[snapshot] from a
 * drag gesture). libghostty-vt's own docs say concurrent access needs an
 * external lock (see the render-state API's "safely multi-threaded... as
 * long as a lock is held" note in ghostty/include/ghostty/vt/render.h), so
 * every native call here — including [close], to avoid a use-after-free if
 * it races an in-flight call — goes through [lock].
 */
class GhosttyTerminal(
    columns: Int,
    rows: Int,
    maxScrollback: Long = 10_000L,
) : AutoCloseable {

    private val lock = Any()
    private var terminalPtr: Long
    private var renderStatePtr: Long
    private var closed = false

    init {
        terminalPtr = nativeNewTerminal(columns, rows, maxScrollback)
        renderStatePtr = nativeNewRenderState()
        check(terminalPtr != 0L) { "Failed to create libghostty-vt terminal" }
        check(renderStatePtr != 0L) { "Failed to create libghostty-vt render state" }
    }

    /**
     * Feeds raw VT/ANSI bytes through the real Ghostty parser. Writing is the same
     * code path real terminals use for keystroke echo, and Ghostty's normal behavior
     * is to snap the viewport back to the active area on any write — appropriate for
     * a live keystroke, but not for a scrolled-up user watching unrelated new output
     * arrive underneath them. So this explicitly saves and restores the viewport's
     * scroll position around the write whenever the user isn't already at the bottom.
     */
    fun write(bytes: ByteArray) {
        synchronized(lock) {
            if (closed) return
            val wasAtBottom = nativeIsViewportActive(terminalPtr)
            val savedOffset = if (wasAtBottom) 0L else nativeScrollOffset(terminalPtr)
            nativeVtWrite(terminalPtr, bytes)
            if (!wasAtBottom) {
                nativeScrollViewportToRow(terminalPtr, savedOffset)
            }
        }
    }

    fun resize(columns: Int, rows: Int) {
        synchronized(lock) {
            if (closed) return
            nativeResize(terminalPtr, columns, rows)
        }
    }

    /** Clears the grid/cursor back to a blank state (e.g. when switching terminals). */
    fun reset() {
        synchronized(lock) {
            if (closed) return
            nativeReset(terminalPtr)
        }
    }

    /** Pulls a fresh, paintable snapshot of the current terminal state, or null on failure. */
    fun snapshot(): GhosttyRenderSnapshot? {
        val bytes = synchronized(lock) {
            if (closed) return null
            nativeSnapshot(terminalPtr, renderStatePtr)
        } ?: return null
        return GhosttyRenderSnapshot.decode(bytes)
    }

    /**
     * Scrolls the viewport into scrollback history by [deltaRows] (negative = up/older,
     * positive = down/newer) without touching terminal content. [snapshot] afterward
     * reflects the newly scrolled-to rows. Ghostty clamps this at both the top of
     * scrollback and the bottom of the active area, so over-scrolling is harmless.
     */
    fun scrollBy(deltaRows: Int) {
        synchronized(lock) {
            if (closed) return
            nativeScrollViewportDelta(terminalPtr, deltaRows)
        }
    }

    /** Jumps the viewport back to the live active area (e.g. when the user sends new input). */
    fun scrollToBottom() {
        synchronized(lock) {
            if (closed) return
            nativeScrollViewportToBottom(terminalPtr)
        }
    }

    /** True when the viewport is following the active area; false once scrolled into history. */
    fun isAtBottom(): Boolean {
        synchronized(lock) {
            if (closed) return true
            return nativeIsViewportActive(terminalPtr)
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            nativeFreeRenderState(renderStatePtr)
            nativeFreeTerminal(terminalPtr)
            terminalPtr = 0
            renderStatePtr = 0
        }
    }

    private external fun nativeNewTerminal(columns: Int, rows: Int, maxScrollback: Long): Long
    private external fun nativeFreeTerminal(terminalPtr: Long)
    private external fun nativeReset(terminalPtr: Long)
    private external fun nativeResize(terminalPtr: Long, columns: Int, rows: Int)
    private external fun nativeVtWrite(terminalPtr: Long, data: ByteArray)
    private external fun nativeScrollViewportDelta(terminalPtr: Long, deltaRows: Int)
    private external fun nativeScrollViewportToBottom(terminalPtr: Long)
    private external fun nativeScrollViewportToRow(terminalPtr: Long, row: Long)
    private external fun nativeScrollOffset(terminalPtr: Long): Long
    private external fun nativeIsViewportActive(terminalPtr: Long): Boolean
    private external fun nativeNewRenderState(): Long
    private external fun nativeFreeRenderState(renderStatePtr: Long)
    private external fun nativeSnapshot(terminalPtr: Long, renderStatePtr: Long): ByteArray?

    companion object {
        init {
            System.loadLibrary("ghostty_vt_jni")
        }
    }
}
