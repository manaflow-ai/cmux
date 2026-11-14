import CoreGraphics

/// Rows the Mac's terminal gets (design/terminal R1-1). A full-screen TUI
/// (`top`, `vim`) must fit between the status bar and the composer wherever
/// the composer settled, keyboard up or down, so its header stays on screen.
///
/// - The PTY is resized once, when the keyboard has settled (did-show /
///   did-hide), never per animation frame; during the animation the
///   alternate screen stays pinned to the composer at its old size.
/// - On the primary screen the rows are those of the keyboard-down layout,
///   so showing the keyboard in a shell never redraws its prompt.
/// - When the TUI quits, the shell gets its keyboard-down rows back at once
///   (R2-1): with the TUI's rows kept, the shell's earlier output sat above
///   the screen, unreachable, over a band of black. A resize's mirror reset
///   no longer reports the alternate screen off and on again
///   (`DaemonTerminalInbound.resetMirror(alternate:)`), so this cannot
///   resize the PTY back and forth.
public struct TerminalTUISizing: Equatable, Sendable {
    /// How far the keyboard lifted the composer stack above its resting place
    /// when it last settled (nil: the keyboard is down). A distance, not a
    /// page position: a later dock or page change moves the resting top, and
    /// the rows follow it (a kept position gave a TUI rows under the
    /// composer, or a band of black above it).
    public private(set) var keyboardLift: CGFloat?
    /// Whether the rows follow `keyboardLift` (a TUI was showing when the
    /// keyboard settled, or started since).
    public private(set) var followsKeyboard = false

    public init() {}

    /// The keyboard finished showing or hiding; `stackTop` is the composer
    /// stack's top now, `restingStackTop` its top with the keyboard down.
    public mutating func keyboardSettled(stackTop: CGFloat, restingStackTop: CGFloat, isTUI: Bool) {
        keyboardLift = stackTop < restingStackTop - 0.5 ? restingStackTop - stackTop : nil
        followsKeyboard = isTUI
    }

    /// A TUI took the alternate screen.
    public mutating func tuiStarted() {
        followsKeyboard = true
    }

    /// The TUI left the alternate screen.
    public mutating func tuiEnded() {
        followsKeyboard = false
    }

    /// The rows for the PTY: toolbar to the composer, lifted by the settled
    /// keyboard for a TUI.
    public func rows(restingStackTop: CGFloat, chromeTop: CGFloat, cellHeight: CGFloat) -> Int {
        let bottom = restingStackTop - (followsKeyboard ? keyboardLift ?? 0 : 0)
        return max(1, Int(floor((bottom - chromeTop) / max(1, cellHeight))))
    }
}

/// The rows a full-screen app's area shows while the Mac redraws it at the
/// rows the keyboard settled to (design/terminal R1-1, M-BLACK).
///
/// The page's rows change when the keyboard settles, but the grid on screen
/// is still the Mac's old one until the resize's mirror reset and replay are
/// in (a settle and a round trip later). Sized to the new rows at once, the
/// area moved the old grid off the composer: with the keyboard up its top
/// rows took the area and its status line went under the composer; with the
/// keyboard down it hung from the toolbar over a band of black, with the
/// letterbox note ("53×25 · set by another device") in it. Then the replay
/// moved it again.
///
/// So while that answer is on its way, the area keeps the old grid's rows,
/// pinned to the composer as it was during the keyboard's animation; the
/// replay's frame swaps in the new grid in one step (behind the held frame).
public struct TerminalTUIGridHold: Equatable, Sendable {
    /// The rows of the grid on screen, kept while the Mac's new grid is on
    /// its way (nil: the area shows the page's rows).
    public private(set) var heldRows: Int?

    /// The longest the old grid is kept: the resize's settle and a claim's
    /// round trip (`TerminalReclaimHold.reclaimWait`). Past it, no answer is
    /// coming (the Mac kept its grid) and the area shows the page's rows.
    public static let cap: Duration = TerminalResizeSettle.settle + TerminalReclaimHold.reclaimWait

    public init() {}

    /// The page's rows changed from `old` to `new` while the screen shows the
    /// Mac's grid of `shownRows` rows (nil: a local session, whose grid
    /// follows a resize at once).
    public mutating func rowsChanged(from old: Int, to new: Int, shownRows: Int?) {
        guard let shownRows, shownRows != new else {
            heldRows = nil
            return
        }
        // Held already (the keyboard turned back before the Mac answered):
        // the grid on screen is still the one held.
        if heldRows != nil { return }
        // Only the phone's own grid is held: a grid another device set is
        // shown letterboxed or shifted as it is (TerminalHostGridLayout).
        heldRows = shownRows == old ? shownRows : nil
    }

    /// A replay at the Mac's grid of `rows` rows is parsed; the page has
    /// `page` rows, and `claimPending` says a resize to them is still to be
    /// answered (unsent, or sent after the size this replay answers). The
    /// grid on screen is now the replay's: the area shows the page's rows,
    /// or, while the page's own answer is still coming, the replay's grid
    /// (a second toggle before the first answer: 40, then 25 asked, then 30).
    public mutating func replayed(rows: Int?, page: Int, claimPending: Bool) {
        guard let rows, rows != page, claimPending else {
            heldRows = nil
            return
        }
        heldRows = rows
    }

    /// The app left the alternate screen, or no answer came: the area shows
    /// the page's rows.
    public mutating func release() {
        heldRows = nil
    }

    /// The rows the area shows for the page's `rows`.
    public func rows(page rows: Int) -> Int { heldRows ?? rows }
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
