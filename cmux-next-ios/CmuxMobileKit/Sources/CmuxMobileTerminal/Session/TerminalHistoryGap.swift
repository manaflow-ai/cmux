import Foundation

/// Where a mirror that holds a window far above the Mac's screen jumps from
/// the window's last row to the Mac's screen (`attach-replay-history-window-v1`,
/// ``TerminalSession/historyWindowRows``), and what a reader near it needs.
///
/// After a reset the mirror's rows are the row shift's blank rows
/// (``TerminalRowShift``: the Mac's screen sits at the bottom of the taller
/// mirror), the window's rows, then the Mac's screen. So the first row past
/// the window is `shift + windowRows`, and live output only adds rows below it.
struct TerminalHistoryGap: Equatable {
    /// The mirror's first row after the window (the Mac's screen, or output).
    let row: Int

    init(shift: Int, windowRows: Int) {
        row = max(0, shift) + windowRows
    }

    enum Need: Equatable {
        /// The reader came down to the window's last rows: the window moves
        /// toward the screen (``TerminalSession/loadNewerHistory(toTheScreen:)``).
        case newer
        /// The reader came up from the screen to the gap: the newest rows,
        /// so the rows above the screen are the Mac's.
        case newest
    }

    /// What the reader showing rows `visibleTop..<visibleBottom` needs: coming
    /// down (`movingDown`) to within a screen of the gap from above, newer
    /// rows; coming up to it from below, the newest. A reader going up past
    /// the window's end, or down the Mac's screen, needs nothing: moving the
    /// window then took them away from the rows they scroll toward.
    func need(visibleTop: Int, visibleBottom: Int, movingDown: Bool) -> Need? {
        let screen = max(1, visibleBottom - visibleTop)
        if movingDown {
            // From above: the window's rows on top, its end within a screen.
            return visibleTop < row && visibleBottom + screen >= row ? .newer : nil
        }
        // From below: rows past the window on screen, its end within a screen.
        return visibleBottom > row && visibleTop - screen <= row ? .newest : nil
    }
}
