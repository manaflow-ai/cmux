/// Describes the locale-independent parts of a native key event.
public struct TerminalKeyInputEvent: Sendable, Equatable {
    /// The physical key category used for post-composition routing.
    public let key: TerminalKeyInputKey

    /// Whether Shift, Control, Option, or Command is pressed.
    public let hasModifier: Bool

    /// Text produced after applying libghostty's modifier translation.
    public let translatedText: String?

    /// Text from the original native event before modifier translation.
    public let rawText: String?

    /// Creates a terminal key event description.
    ///
    /// - Parameters:
    ///   - key: The physical key category.
    ///   - hasModifier: Whether a text-relevant modifier is pressed.
    ///   - translatedText: Text produced after terminal modifier translation.
    ///   - rawText: Text from the original native event.
    public init(
        key: TerminalKeyInputKey,
        hasModifier: Bool,
        translatedText: String?,
        rawText: String?
    ) {
        self.key = key
        self.hasModifier = hasModifier
        self.translatedText = translatedText
        self.rawText = rawText
    }
}
