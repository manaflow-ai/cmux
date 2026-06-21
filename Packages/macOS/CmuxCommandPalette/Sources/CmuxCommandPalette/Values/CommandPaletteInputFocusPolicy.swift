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

    /// Focus the rename editor, selecting the existing name or placing the caret
    /// at the end depending on the user's preference.
    ///
    /// - Parameter selectsAllOnFocus: the
    ///   ``CmuxSettings/CommandPaletteSettingsReading/renameSelectsAllOnFocus``
    ///   preference. When `true` the existing name is selected so typing replaces
    ///   it; when `false` the caret sits at the end so typing appends. The host
    ///   reads the preference from its settings store and passes the bool here,
    ///   keeping this factory a pure value transform.
    public static func renameInput(selectsAllOnFocus: Bool) -> CommandPaletteInputFocusPolicy {
        CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectsAllOnFocus ? .selectAll : .caretAtEnd
        )
    }
}
