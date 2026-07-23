/// Captures one AppKit text-interpretation transition for terminal routing.
public struct TerminalKeyInputSnapshot: Sendable, Equatable {
    /// Whether marked text existed before AppKit interpreted the key.
    public let hadMarkedText: Bool

    /// Whether marked text exists after AppKit interpreted the key.
    public let hasMarkedText: Bool

    /// Whether AppKit changed the selected input source while handling the key.
    public let inputSourceChanged: Bool

    /// Text committed by AppKit while interpreting the key.
    public let committedText: [String]

    /// The locale-independent native key description.
    public let event: TerminalKeyInputEvent

    /// Creates a text-interpretation snapshot.
    ///
    /// - Parameters:
    ///   - hadMarkedText: Whether composition was active before interpretation.
    ///   - hasMarkedText: Whether composition remains active after interpretation.
    ///   - inputSourceChanged: Whether the selected input source changed.
    ///   - committedText: Text committed during interpretation.
    ///   - event: The translated native key description.
    public init(
        hadMarkedText: Bool,
        hasMarkedText: Bool,
        inputSourceChanged: Bool,
        committedText: [String],
        event: TerminalKeyInputEvent
    ) {
        self.hadMarkedText = hadMarkedText
        self.hasMarkedText = hasMarkedText
        self.inputSourceChanged = inputSourceChanged
        self.committedText = committedText
        self.event = event
    }
}
