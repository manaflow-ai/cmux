/// A cursor or visual-selection movement supported by terminal keyboard copy mode.
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
}
