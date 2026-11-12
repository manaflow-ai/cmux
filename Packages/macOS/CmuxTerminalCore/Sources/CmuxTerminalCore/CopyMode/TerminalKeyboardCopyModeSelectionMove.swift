/// A cursor or visual-selection movement supported by terminal keyboard copy mode.
///
/// `TerminalKeyboardCopyModeSelectionMove` describes the movement component of
/// ``TerminalKeyboardCopyModeAction.adjustSelection(_:)``. The terminal host
/// applies the same cases to the visible copy-mode cursor outside visual mode
/// and to Ghostty's selection endpoint while visual mode is active.
///
/// Word cases need the row text, so the host resolves them with
/// ``TerminalKeyboardCopyModeWordMotion`` and applies the result as a
/// beginning-of-line move followed by a glyph count of right moves.
///
/// ```swift
/// let move: TerminalKeyboardCopyModeSelectionMove = .pageUp
/// let action = TerminalKeyboardCopyModeAction.adjustSelection(move)
/// ```
///
/// The enum has no initializer parameters and does not throw.
public enum TerminalKeyboardCopyModeSelectionMove: String, Equatable, Sendable {
    /// Moves one or more cells left.
    case left

    /// Moves one or more cells right.
    case right

    /// Moves one or more rows up.
    case up

    /// Moves one or more rows down.
    case down

    /// Moves one or more pages up.
    case pageUp = "page_up"

    /// Moves one or more pages down.
    case pageDown = "page_down"

    /// Moves to the top-left cell.
    case home

    /// Moves to the bottom-right cell.
    case end

    /// Moves to the first cell in the current row.
    case beginningOfLine = "beginning_of_line"

    /// Moves to the last cell in the current row.
    case endOfLine = "end_of_line"

    /// Moves to the start of the next word (vim `w`).
    case wordForward = "word_forward"

    /// Moves to the start of the current or previous word (vim `b`).
    case wordBackward = "word_backward"

    /// Moves to the end of the current or next word (vim `e`).
    case wordEndForward = "word_end_forward"

    /// Moves to the start of the next whitespace-delimited word (vim `W`).
    case bigWordForward = "big_word_forward"

    /// Moves to the start of the current or previous whitespace-delimited word (vim `B`).
    case bigWordBackward = "big_word_backward"

    /// Moves to the end of the current or next whitespace-delimited word (vim `E`).
    case bigWordEndForward = "big_word_end_forward"
}
