/// One textual MIME representation supplied by the terminal runtime for a
/// single clipboard write.
public struct TerminalClipboardRepresentation: Equatable, Sendable {
    /// The MIME type, optionally including parameters such as a text charset.
    ///
    /// The pasteboard service maps `text/plain`, `text/html`, and `text/rtf`
    /// to their native pasteboard types and preserves other identifiers.
    public let mimeType: String

    /// The UTF-8-decoded textual payload for this representation.
    public let string: String

    /// Creates a textual clipboard representation.
    ///
    /// - Parameters:
    ///   - mimeType: The MIME type, with optional parameters.
    ///   - string: The decoded textual payload.
    public init(mimeType: String, string: String) {
        self.mimeType = mimeType
        self.string = string
    }
}
