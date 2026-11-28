import Foundation

/// Pairs the input to focus with the selection behavior to apply on focus.
public struct CommandPaletteInputFocusPolicy: Sendable {
    /// The input to focus.
    public let focusTarget: CommandPaletteInputFocusTarget
    /// The selection applied once focused.
    public let selectionBehavior: CommandPaletteTextSelectionBehavior

    /// Creates a focus policy.
    public init(
        focusTarget: CommandPaletteInputFocusTarget,
        selectionBehavior: CommandPaletteTextSelectionBehavior
    ) {
        self.focusTarget = focusTarget
        self.selectionBehavior = selectionBehavior
    }

    /// Focus the search field with the caret at the end.
    public static let search = CommandPaletteInputFocusPolicy(
        focusTarget: .search,
        selectionBehavior: .caretAtEnd
    )
}
