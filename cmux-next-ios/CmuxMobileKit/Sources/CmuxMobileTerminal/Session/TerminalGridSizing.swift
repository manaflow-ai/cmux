import CoreGraphics

/// The grid the phone claims, and how the page shows it while the soft
/// keyboard is up (Leo, 2026-11-12: "the resizing is so wack when j tap the
/// thijg"; 2026-11-15: "i meant previously there was the thing that stopped
/// the resizing when you closed the ios built in keyboard").
///
/// - The rows are those of the keyboard-down layout, the toolbar's bottom to
///   the composer stack's resting top, for a shell and a full-screen TUI
///   alike. The soft keyboard showing or closing never resizes the remote
///   PTY: a resize makes the Mac reset the mirror and the app (Claude Code,
///   Codex, vim) redraw, which reads as the content jumping on every keyboard
///   tap. Only the page's own size (rotation, split view, window size), its
///   chrome (Hide Toolbar, the composer, a tab's insets) and the font change
///   the rows, and `TerminalResizeSettle` debounces and deduplicates what
///   reaches the Mac.
/// - With the keyboard up, a TUI's grid keeps its rows and is inset instead:
///   its bottom rides the composer stack inside the keyboard's own animation
///   (Auto Layout on the keyboard layout guide), its top is clipped under the
///   toolbar, and `keyboardLift` moves it down only as far as the cursor's row
///   needs to stay on screen.
/// - The top exception (Leo, 2026-11-15: "just... add the thing? add the top
///   exception? why roll the whole thing back"): while the keyboard clips a
///   full-screen app's top, its first `headerRows` rows (Claude Code's header
///   box, htop's meters, vim's first lines) stay pinned at the top of the
///   area, drawn from the same frame, over a body that keeps the cursor's row
///   in view (`keyboardPlacement`). Nothing is resized: the phone shows the
///   rows it already has, twice.
public struct TerminalGridSizing: Equatable, Sendable {
    public var cellHeight: CGFloat
    /// The app's rows pinned above the body while the keyboard clips its top.
    /// A fixed count: the header box of Claude Code and Codex is three rows,
    /// and the phone does not see the app's scroll margins (Ghostty keeps
    /// them). Capped at a third of the visible rows, so the body keeps two
    /// thirds of the area.
    public var headerRows: Int

    public static let defaultHeaderRows = 3

    public init(cellHeight: CGFloat, headerRows: Int = TerminalGridSizing.defaultHeaderRows) {
        self.cellHeight = cellHeight
        self.headerRows = headerRows
    }

    /// Where a full-screen app's grid sits while the keyboard clips it.
    public struct KeyboardPlacement: Equatable, Sendable {
        /// How far the grid moves down (points, whole rows or the whole clipped part).
        public var lift: CGFloat
        /// The grid's first rows pinned at the top of the area (0: none).
        public var headerRows: Int

        public init(lift: CGFloat, headerRows: Int) {
            self.lift = lift
            self.headerRows = headerRows
        }
    }

    /// The top exception: the header rows stay at the top of the area and the
    /// body under them is lifted only as far as the cursor's row needs. No
    /// header while the grid fits, while the lift already shows the grid's
    /// top (the cursor is near it), or when the cursor is in the header rows
    /// (the grid's top is shown as it is).
    ///
    /// `areaRows`: the area's rows (the host, bottom-pinned to the stack) when
    /// the grid is shorter and sits at its top (a Mac grid smaller than the
    /// page). The empty rows under the grid are lifted out first, so the grid
    /// keeps its place under the toolbar and only what is still clipped moves.
    public func keyboardPlacement(gridRows: Int, visibleHeight: CGFloat, cursorRow: Int?,
                                  areaRows: Int? = nil) -> KeyboardPlacement {
        guard cellHeight > 0, gridRows > 0 else { return KeyboardPlacement(lift: 0, headerRows: 0) }
        if let areaRows, areaRows > gridRows {
            let blank = max(0, min(CGFloat(areaRows) * cellHeight - max(0, visibleHeight),
                                   CGFloat(areaRows - gridRows) * cellHeight))
            var placement = keyboardPlacement(gridRows: gridRows, visibleHeight: visibleHeight, cursorRow: cursorRow)
            placement.lift += blank
            return placement
        }
        let clipped = CGFloat(gridRows) * cellHeight - max(0, visibleHeight)
        guard clipped > 0.5 else { return KeyboardPlacement(lift: 0, headerRows: 0) }
        let header = max(0, min(headerRows, Int(floor(max(0, visibleHeight) / cellHeight)) / 3))
        if let cursorRow, cursorRow < header { return KeyboardPlacement(lift: clipped, headerRows: 0) }
        // The header covers the area's first rows: the body is that much shorter.
        let lift = keyboardLift(gridRows: gridRows, visibleHeight: visibleHeight - CGFloat(header) * cellHeight, cursorRow: cursorRow)
        guard lift < clipped - 0.5 else { return KeyboardPlacement(lift: clipped, headerRows: 0) }
        return KeyboardPlacement(lift: lift, headerRows: header)
    }

    /// The rows for the PTY: keyboard-down geometry only.
    public func rows(restingStackTop: CGFloat, chromeTop: CGFloat) -> Int {
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
    public func keyboardLift(gridRows: Int, visibleHeight: CGFloat, cursorRow: Int?) -> CGFloat {
        guard cellHeight > 0, gridRows > 0 else { return 0 }
        let clipped = CGFloat(gridRows) * cellHeight - max(0, visibleHeight)
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
/// goes at once (the attach needs it).
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
