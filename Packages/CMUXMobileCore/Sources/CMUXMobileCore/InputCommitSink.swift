/// Which delegate path a committed block of input text was routed to.
///
/// Encoded into the `b` slot of ``DiagnosticEventCode/inputCommitRouted`` so a
/// device dogfood can trace a dictation result (or typed character) from
/// `insertText(_:)` all the way to the byte path that reaches the Mac, using
/// only the integer ``DiagnosticEvent`` payload. Decoded by
/// `scripts/decode-ios-diagnostic.py`.
public enum InputCommitSink: Int, Sendable, Codable, CaseIterable {
    /// Per-character raw input (`onText` → `terminal.input`). Single characters
    /// and Return take this path.
    case text = 0
    /// Bracketed paste (`onPasteText` → `terminal.paste`). A multi-character
    /// block with no active modifier — system dictation, an autocorrect
    /// replacement, or keyboard-inserted clipboard text — takes this path. A
    /// dictation result that fires should land here.
    case pasteText = 1
    /// An escape / control sequence (`onEscapeSequence`). A modifier
    /// (Ctrl/Alt/Cmd) transformed the committed text into bytes.
    case escapeSequence = 2
}
