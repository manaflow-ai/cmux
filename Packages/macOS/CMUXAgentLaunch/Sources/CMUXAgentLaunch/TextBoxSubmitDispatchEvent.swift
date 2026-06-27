/// A single planned input action for a textbox submission.
///
/// `Array<TextBoxSubmissionPart>.textBoxDispatchEvents(terminalAgentContext:)`
/// produces an ordered list of these events; the app's event runner executes
/// them against a terminal surface.
public enum TextBoxSubmitDispatchEvent: Equatable {
    /// Send literal key text.
    case keyText(String)
    /// Paste the given text.
    case pasteText(String)
    /// Paste a file path (used for image attachments).
    case pasteFilePath(String)
    /// Send a named key repeated a number of times.
    case namedKeyRepeat(String, Int)
    /// Send a single named key.
    case namedKey(String)
    /// Capture the clipboard-read baseline before a paste.
    case captureClipboardReadBaseline
    /// Wait until the clipboard read completes.
    case waitForClipboardRead
    /// Capture the visible-text baseline before a paste.
    case captureVisibleTextBaseline
    /// Wait until the given text becomes visible.
    case waitForVisibleText(String)
    /// Capture the Claude image-token baseline.
    case captureClaudeImageTokenBaseline
    /// Wait until the given Claude image token is confirmed.
    case waitForClaudeImageToken(String)
}
