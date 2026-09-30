import Foundation

/// The kind of focus target dictation text is routed into.
public enum DictationInsertionRoute: Equatable, Sendable {
    /// A native `NSTextView`/`NSTextField` (including SwiftUI text fields
    /// and field editors); text goes through `insertText(_:)`.
    case nativeTextResponder

    /// An editable element inside a `WKWebView` (agent composer, browser
    /// pane); text is inserted via JavaScript.
    case webViewEditable

    /// The focused terminal surface; text is written to the PTY through
    /// the typed-input path.
    case terminalSurface
}
