/// Identifies the physical key behavior needed after AppKit text interpretation.
public enum TerminalKeyInputKey: Sendable, Equatable {
    /// The left-arrow key.
    case arrowLeft

    /// The right-arrow key.
    case arrowRight

    /// The up-arrow key.
    case arrowUp

    /// The down-arrow key.
    case arrowDown

    /// Any key without special post-composition behavior.
    case other
}
