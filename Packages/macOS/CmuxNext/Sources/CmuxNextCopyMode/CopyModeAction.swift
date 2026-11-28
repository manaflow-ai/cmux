/// A copy-mode command resolved from keyboard input. The terminal view
/// applies it to Ghostty's keyboard-copy cursor, selection, and viewport.
public enum CopyModeAction: Equatable, Sendable {
    /// Leaves copy mode.
    case exit
    /// Starts a character selection at the cursor (`v`).
    case startSelection
    /// Starts a line selection at the cursor row (`V`).
    case startLineSelection
    /// Clears the selection and stays in copy mode (`v` while selecting).
    case clearSelection
    /// Copies the selection and leaves copy mode (`y`).
    case copyAndExit
    /// Copies whole lines from the cursor row and leaves (`yy`, `Y`).
    case copyLineAndExit
    /// Scrolls the viewport by signed lines (Ctrl-Y, Ctrl-E).
    case scrollLines(Int)
    /// Scrolls the viewport by signed pages (Ctrl-B, Ctrl-F, Page Up/Down).
    case scrollPage(Int)
    /// Scrolls the viewport by signed half pages (Ctrl-U, Ctrl-D).
    case scrollHalfPage(Int)
    /// Moves to the top-left cell of the scrollback (`gg`, Home).
    case scrollToTop
    /// Moves to the bottom-right cell (`G`, End).
    case scrollToBottom
    /// Jumps by signed shell prompts (`{`, `}`).
    case jumpToPrompt(Int)
    /// Opens terminal search (`/`).
    case startSearch
    /// Next search match (`n`).
    case searchNext
    /// Previous search match (`N`).
    case searchPrevious
    /// Moves the cursor, or the selection's moving end while selecting.
    case adjustSelection(CopyModeMove)
}

/// A cursor or selection-endpoint movement.
public enum CopyModeMove: String, Equatable, Sendable, CaseIterable {
    case left
    case right
    case up
    case down
    case pageUp = "page_up"
    case pageDown = "page_down"
    /// Top-left cell.
    case home
    /// Bottom-right cell.
    case end
    case beginningOfLine = "beginning_of_line"
    case endOfLine = "end_of_line"
}

/// The result of one key event: perform an action `count` times, or only
/// update pending state (a count prefix, the first `g` or `y`).
public enum CopyModeResolution: Equatable, Sendable {
    case perform(CopyModeAction, count: Int)
    case consume
}
