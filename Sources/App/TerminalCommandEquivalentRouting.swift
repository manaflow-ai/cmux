import AppKit

/// Owns the terminal-first policy for standard Edit-menu command equivalents.
///
/// AppKit offers a menu key equivalent before it sends the event to the focused
/// view. A terminal has a richer interpretation of these chords (including
/// performable Ghostty bindings and kitty-protocol application keys), so the
/// window router offers the event to the terminal before asking the menu.
struct TerminalCommandEquivalentRouter {
    enum Command: String, Equatable {
        case copy
        case paste
        case cut
        case selectAll
        case undo
        case redo
    }

    /// Identifies the standard Edit-menu command represented by `event`.
    /// Non-standard modifiers are intentionally excluded so cmux-owned custom
    /// shortcuts and Ghostty option/control bindings keep their normal routes.
    func command(for event: NSEvent) -> Command? {
        guard event.type == .keyDown else { return nil }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let key = KeyboardLayout.normalizedCharacters(for: event).lowercased()

        switch (flags, key) {
        case ([.command], "c"):
            return .copy
        case ([.command], "v"):
            return .paste
        case ([.command], "x"):
            return .cut
        case ([.command], "a"):
            return .selectAll
        case ([.command], "z"):
            return .undo
        case ([.command, .shift], "z"):
            return .redo
        default:
            return nil
        }
    }

    /// Offers a standard Edit equivalent to a focused terminal.
    ///
    /// `false` means the terminal declined the event (or the event is not
    /// applicable), so the caller may continue with normal AppKit menu
    /// dispatch. Only a successful terminal dispatch consumes the equivalent.
    @discardableResult
    func route(
        event: NSEvent,
        terminalView: GhosttyNSView,
        firstResponder: NSResponder?,
        hasActiveShortcutChord: Bool
    ) -> Bool {
        guard !hasActiveShortcutChord,
              command(for: event) != nil,
              !Self.preservesLocalTextEditing(firstResponder) else {
            return false
        }

        // This is the same terminal path used after a menu miss. It lets
        // Ghostty decide whether Copy/Paste are performable actions, preserving
        // copy-with-selection while forwarding the chord to a focused TUI when
        // there is no terminal selection.
        if terminalView.performKeyEquivalentAfterMenuMiss(with: event) {
            return true
        }

        // A declined terminal equivalent must remain available to the native
        // responder/menu path. This is important for transient surfaces and for
        // terminal-owned descendants that intentionally do not claim a chord.
        return false
    }

    private static func preservesLocalTextEditing(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }

        if let textField = responder as? NSTextField {
            if textField.isEditable { return true }
            if let editor = textField.currentEditor() {
                return editor.isEditable || editor.isFieldEditor
            }
        }

        return false
    }
}
