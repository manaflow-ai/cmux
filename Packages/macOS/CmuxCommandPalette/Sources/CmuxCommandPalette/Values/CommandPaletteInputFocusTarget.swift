import Foundation

/// Which palette text input should receive keyboard focus.
public enum CommandPaletteInputFocusTarget: Sendable, Equatable {
    /// The search field.
    case search
    /// The rename/description editor.
    case rename
}
