internal import AppKit

/// Default platform clipboard sink used by the AppKit interaction host.
@MainActor
public final class TerminalFrontendSystemClipboardWriter: TerminalFrontendClipboardWriting {
    /// Creates a sink backed by `NSPasteboard.general`.
    public init() {}

    /// Replaces the general pasteboard with one plain-text terminal selection.
    ///
    /// - Parameter text: The canonical terminal selection text.
    /// - Returns: Whether AppKit accepted the text.
    @discardableResult
    public func writeTerminalText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
