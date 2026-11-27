// Cmd-Z and Shift-Cmd-Z belong to the text being edited (https://github.com/manaflow-ai/cmux/issues/38148).
// Ghostty's macOS defaults bind `super+z=undo`, which the App folds into its binding table as a
// `.ghosttyFallback` entry (Reopen Last Closed Item). Taken by that fallback, Cmd-Z in the agent
// chat or Chief composer reopened a closed tab and never reached the page's own undo. Where text is
// edited, a Ghostty default never wins these chords: the page or field runs Undo and Redo, and Edit >
// Undo does when it does not. A keybind the user wrote in their Ghostty config still wins.

nonisolated extension KeyContext {
    /// Whether a key in this context goes where a person edits text: a text field (`textInputFocus`,
    /// also an editable element in a page), or content that is not a terminal or an empty pane (a
    /// page, an agent chat, Home). A terminal runs Ghostty's own keybinds; the sidebar and an empty
    /// pane have no text to undo.
    public var editsText: Bool {
        if self[Self.textInputFocus] == .bool(true) { return true }
        guard self[Self.focus] == .string("content") || self[Self.focus] == .string("none"),
              case .string(let kind)? = self[Self.surfaceKind] else { return false }
        return kind != "terminal" && kind != "empty"
    }
}

nonisolated extension KeyBinding {
    /// Undo and Redo of the text being edited.
    public static let textUndoChords: Set<Shortcut> = [
        Shortcut("z", modifiers: [.command]), Shortcut("z", modifiers: [.command, .shift]),
    ]

    /// This binding is on Cmd-Z or Shift-Cmd-Z alone.
    public var isTextUndoChord: Bool {
        keys.count == 1 && keys.first.map(Self.textUndoChords.contains) == true
    }
}
