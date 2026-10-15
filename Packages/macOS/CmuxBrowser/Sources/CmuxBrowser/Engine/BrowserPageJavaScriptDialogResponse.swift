import Foundation

/// The answer to a ``BrowserPageJavaScriptDialog``.
public enum BrowserPageJavaScriptDialogResponse: Equatable, Hashable, Sendable {
    /// OK / Leave; `text` is the prompt's input (ignored by other kinds).
    case accept(text: String?)
    /// Cancel / Stay.
    case dismiss
}
