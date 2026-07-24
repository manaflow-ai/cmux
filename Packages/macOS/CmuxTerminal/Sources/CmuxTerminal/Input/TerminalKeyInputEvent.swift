/// Describes the locale-independent parts of a native key event.
public struct TerminalKeyInputEvent: Sendable, Equatable {
    /// Text produced after applying libghostty's modifier translation.
    public let translatedText: String?

    /// Text from the original native event before modifier translation.
    public let rawText: String?

    /// Creates a terminal key event description.
    ///
    /// - Parameters:
    ///   - translatedText: Text produced after terminal modifier translation.
    ///   - rawText: Text from the original native event.
    public init(
        translatedText: String?,
        rawText: String?
    ) {
        self.translatedText = translatedText
        self.rawText = rawText
    }
}
