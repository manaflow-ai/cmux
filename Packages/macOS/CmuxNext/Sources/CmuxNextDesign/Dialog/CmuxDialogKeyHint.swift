import Foundation

/// The key that presses one dialog button, as the button shows it (u2647: every
/// dialog button says which key presses it, "Cancel ⎋", "Change ↩", "Don't Save ⌘D").
///
/// A hint is derived from the same rules that answer the keys
/// (``CmuxDialogKeys/hint(for:in:)``), so a button never shows a key that does not
/// press it: `CmuxDialogKeys.action(for: hint.key, modifiers: hint.modifiers, in: spec)`
/// is always `.press(button.id)`.
public nonisolated enum CmuxDialogKeyHint: Equatable, Sendable {
    /// Return presses the button (the dialog's default button).
    case `return`
    /// Escape presses the button (the dialog's cancel button).
    case escape
    /// Command plus this lowercase character presses the button.
    case command(Character)

    /// The keycap text drawn after the title, as macOS menus write keys: `↩`, `⎋`, `⌘D`.
    public var glyph: String {
        switch self {
        case .return: "↩"
        case .escape: "⎋"
        case .command(let character): "⌘" + character.uppercased()
        }
    }

    /// The key as VoiceOver reads it ("Return", "Escape", "Command-D").
    public var spokenName: String {
        switch self {
        case .return: CmuxDialogStrings.keyReturn
        case .escape: CmuxDialogStrings.keyEscape
        case .command(let character): CmuxDialogStrings.keyCommand(character.uppercased())
        }
    }

    /// The dialog key this hint names, for ``CmuxDialogKeys/action(for:modifiers:in:)``.
    public var key: CmuxDialogKeys.Key {
        switch self {
        case .return: .return
        case .escape: .escape
        case .command(let character): .character(character)
        }
    }

    /// The modifiers held with ``key``.
    public var modifiers: CmuxDialogKeys.Modifiers {
        if case .command = self { return .command }
        return []
    }
}
