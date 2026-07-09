import Foundation

/// How text is selected when a palette input gains programmatic focus.
public enum CommandPaletteTextSelectionBehavior: Sendable, Equatable {
    /// Place the caret at the end without selecting.
    case caretAtEnd
    /// Select the whole text.
    case selectAll
}
