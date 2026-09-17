/// Main-actor clipboard sink for text returned by the canonical terminal runtime.
@MainActor
public protocol TerminalFrontendClipboardWriting: AnyObject {
    /// Replaces the platform clipboard with one canonical terminal text value.
    ///
    /// - Parameter text: Nonempty terminal selection text.
    /// - Returns: Whether the platform clipboard accepted the value.
    @discardableResult
    func writeTerminalText(_ text: String) -> Bool
}
