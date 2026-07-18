internal import AppKit

/// Default platform clipboard source used by the AppKit responder chain.
@MainActor
public final class TerminalFrontendSystemClipboardReader: TerminalFrontendClipboardReading {
    /// Creates a source backed by `NSPasteboard.general`.
    public init() {}

    /// Checks pasteboard type metadata without copying the clipboard payload.
    public var hasTerminalText: Bool {
        NSPasteboard.general.availableType(from: [.string]) != nil
    }

    /// Returns the general pasteboard's plain-text representation.
    public func readTerminalText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
