import CoreGraphics

/// The grid the phone claims, and how the page shows it while the soft
/// keyboard is up (Leo, 2026-11-12: "the resizing is so wack when j tap the
/// thijg").
///
/// - The rows are those of the keyboard-down layout, the toolbar's bottom to
///   the composer stack's resting top, for a shell and a full-screen TUI
///   alike. The soft keyboard never resizes the remote PTY: a resize makes the
///   Mac reset the mirror and the TUI redraw, which read as the content
///   jumping each time the key bar's keyboard button was tapped. Only the
///   page's own size (rotation, split view, window size), the chrome (Hide
///   Toolbar, the composer) and the font change the rows, and
///   `TerminalResizeSettle` debounces and deduplicates what reaches the Mac.
/// - With the keyboard up, a TUI's grid keeps its rows and is inset instead:
///   its bottom rides the composer stack inside the keyboard's own animation
///   (Auto Layout on the keyboard layout guide), its top is clipped under the
///   toolbar, and `keyboardLift` moves it down only as far as the cursor's row
///   needs to stay on screen.
public enum TerminalGridSizing {
    /// The rows for the PTY: keyboard-down geometry only.
    public static func rows(restingStackTop: CGFloat, chromeTop: CGFloat, cellHeight: CGFloat) -> Int {
        max(1, Int(floor((restingStackTop - chromeTop) / max(1, cellHeight))))
    }

    /// How far a TUI's grid (bottom-pinned to the composer stack's top) moves
    /// down, in points, so the cursor's row stays visible while the keyboard
    /// covers the bottom of the page. 0 while the whole grid fits, or the
    /// cursor is already below the clipped top; never more than the clipped
    /// part. Whole rows, so no row is cut at the top edge by the lift itself.
    ///
    /// - Parameters:
    ///   - gridRows: rows of the grid (the claimed rows).
    ///   - visibleHeight: the TUI area's height now (toolbar to stack top).
    ///   - cursorRow: the cursor's row from the grid's top (nil: unknown).
    ///   - pinnedHeight: the height a shorter Mac grid (and its note) takes at the grid's top,
    ///     when another device set one: while it fits, the lift shows it whole (its top at the
    ///     area's top), whatever the cursor's row.
    public static func keyboardLift(gridRows: Int, visibleHeight: CGFloat, cursorRow: Int?, cellHeight: CGFloat,
                                    pinnedHeight: CGFloat? = nil) -> CGFloat {
        guard cellHeight > 0, gridRows > 0 else { return 0 }
        let clipped = CGFloat(gridRows) * cellHeight - max(0, visibleHeight)
        if clipped > 0.5, let pinnedHeight, pinnedHeight <= max(0, visibleHeight) + 0.5 { return clipped }
        guard clipped > 0.5, let cursorRow, cursorRow >= 0 else { return 0 }
        let cursorTop = CGFloat(min(cursorRow, gridRows - 1)) * cellHeight
        guard cursorTop < clipped else { return 0 }
        let rows = ceil((clipped - cursorTop) / cellHeight - 0.001)
        return min(clipped, rows * cellHeight)
    }
}

/// When a new grid size reaches the Mac (user report 2026-10-14, "blinking
/// and oscillating"). Every resize makes the Mac reset the phone's mirror and
/// replay the whole history, and an inline TUI such as Codex redraw its whole
/// transcript. Layout passes measured the page mid-change (the toolbar or
/// keyboard insets in flux) and sent 53x39 then 53x42 40 ms apart: two resets
/// and two full redraws for nothing. A size goes to the Mac only once it has
/// held for `settle`; one that reverts before then is dropped. The first size
/// goes at once (the attach needs it). The soft keyboard never measures a
/// new size (`TerminalGridSizing`), so it never reaches here.
public struct TerminalResizeSettle: Equatable, Sendable {
    public struct Size: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
    }

    public static let settle: Duration = .milliseconds(250)

    /// The size the Mac was last given.
    public private(set) var applied: Size?
    /// A size measured but not yet sent.
    public private(set) var pending: Size?

    public init() {}

    public enum Action: Equatable, Sendable {
        /// Send now (the first size).
        case sendNow(Size)
        /// Wait `settle`, then ask `settled()`.
        case wait
        case nothing
    }

    /// The layout measured `size`.
    public mutating func measured(_ size: Size) -> Action {
        guard let applied else {
            self.applied = size
            pending = nil
            return .sendNow(size)
        }
        if size == applied {
            pending = nil
            return .nothing
        }
        if pending == size { return .nothing }
        pending = size
        return .wait
    }

    /// `settle` passed since the last change: the size to send, if any.
    public mutating func settled() -> Size? {
        guard let size = pending else { return nil }
        pending = nil
        applied = size
        return size
    }
}
