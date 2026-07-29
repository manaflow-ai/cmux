/// Describes the locale-independent parts of a native key event.
public struct TerminalKeyInputEvent: Sendable, Equatable {
    /// Text produced after applying libghostty's modifier translation.
    public let translatedText: String?

    /// Text from the original native event before modifier translation.
    public let rawText: String?

    /// Whether Ghostty replays this physical key after preedit text commits.
    public let replaysPhysicalKeyAfterPreeditCommit: Bool

    /// Creates a terminal key event description.
    ///
    /// - Parameters:
    ///   - translatedText: Text produced after terminal modifier translation.
    ///   - rawText: Text from the original native event.
    ///   - replaysPhysicalKeyAfterPreeditCommit: Whether the physical key must
    ///     still affect the terminal after AppKit commits preedit text.
    public init(
        translatedText: String?,
        rawText: String?,
        replaysPhysicalKeyAfterPreeditCommit: Bool = false
    ) {
        self.translatedText = translatedText
        self.rawText = rawText
        self.replaysPhysicalKeyAfterPreeditCommit =
            replaysPhysicalKeyAfterPreeditCommit
    }
}
