/// Cmd+Z at a shell prompt, replayed as the line editor's own undo key.
///
/// A terminal has no text model of its own: the characters at a prompt belong
/// to the shell's line editor (readline, zle, fish, or an agent's composer),
/// and only that editor can restore a deleted word. Their default emacs-style
/// keymaps read `Ctrl+_` (byte `0x1F`) as undo, so Cmd+Z sends that byte
/// instead of the Super-modified `z` that macOS terminals encode as nothing
/// at all (https://github.com/manaflow-ai/cmux/issues/26459).
///
/// The terminal cannot tell a line editor from any other program reading the
/// main screen, so a program without one (`cat`, a plain `read`) receives the
/// byte as input, as it would from a typed `Ctrl+_`.
public struct TerminalLineEditorUndo: Equatable, Sendable {
    /// The Ghostty binding action that writes `Ctrl+_` to the pty.
    ///
    /// A raw byte rather than a synthesized key event: no layout has a
    /// `Ctrl+_` key that every keyboard protocol encodes the same way, and line
    /// editors read the legacy C0 byte even after negotiating `CSI u`.
    public static let bindingAction = "text:\\x1f"

    /// The event is exactly Cmd+Z in the current layout, with no Shift,
    /// Option, or Control.
    public var isUndoChord: Bool
    /// The user's Ghostty config binds the chord, which then wins over this
    /// default.
    public var hasGhosttyBinding: Bool
    /// An input method has marked text, which owns the key.
    public var isComposing: Bool
    /// Copy mode owns the keyboard.
    public var keyboardCopyModeActive: Bool

    /// Captures the owners of a possible line-editor undo keystroke.
    ///
    /// - Parameters:
    ///   - isUndoChord: Whether the event is exactly the Undo menu equivalent.
    ///   - hasGhosttyBinding: Whether a user binding or active key sequence owns the key.
    ///   - isComposing: Whether an input method owns marked text.
    ///   - keyboardCopyModeActive: Whether keyboard copy mode owns the key.
    public init(
        isUndoChord: Bool,
        hasGhosttyBinding: Bool,
        isComposing: Bool,
        keyboardCopyModeActive: Bool
    ) {
        self.isUndoChord = isUndoChord
        self.hasGhosttyBinding = hasGhosttyBinding
        self.isComposing = isComposing
        self.keyboardCopyModeActive = keyboardCopyModeActive
    }

    /// Whether the keystroke should be replayed as line-editor undo.
    ///
    /// - Parameter isAlternateScreenActive: Read only when every other
    ///   condition holds, because it serializes the viewport. A full-screen
    ///   application decides what its own keys mean, so it keeps the original
    ///   keystroke. `nil` means the screen could not be read, which also keeps
    ///   the original keystroke rather than writing `0x1F` into an
    ///   application that may be full-screen.
    /// - Returns: `true` when the caller should send ``bindingAction`` and
    ///   consume the keystroke.
    public func shouldReplay(isAlternateScreenActive: () -> Bool?) -> Bool {
        guard isUndoChord, !hasGhosttyBinding, !isComposing, !keyboardCopyModeActive else {
            return false
        }
        return isAlternateScreenActive() == false
    }
}
