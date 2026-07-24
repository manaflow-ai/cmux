/// Captures one AppKit text-interpretation transition for terminal routing.
public struct TerminalKeyInputSnapshot: Sendable, Equatable {
    /// Whether marked text existed before AppKit interpreted the key.
    public let hadMarkedText: Bool

    /// Whether marked text exists after AppKit interpreted the key.
    public let hasMarkedText: Bool

    /// Whether the Cocoa text input context consumed the native event.
    public let textInputConsumed: Bool

    /// Whether text input delegated a command back to the terminal client.
    public let textInputCommandPerformed: Bool

    /// Text committed by AppKit while interpreting the key.
    public let committedText: [String]

    /// The locale-independent native key description.
    public let event: TerminalKeyInputEvent

    /// Creates a text-interpretation snapshot.
    ///
    /// - Parameters:
    ///   - hadMarkedText: Whether composition was active before interpretation.
    ///   - hasMarkedText: Whether composition remains active after interpretation.
    ///   - textInputConsumed: Whether Cocoa text input consumed the event.
    ///   - textInputCommandPerformed: Whether text input delegated a command.
    ///   - committedText: Text committed during interpretation.
    ///   - event: The translated native key description.
    public init(
        hadMarkedText: Bool,
        hasMarkedText: Bool,
        textInputConsumed: Bool = false,
        textInputCommandPerformed: Bool = false,
        committedText: [String],
        event: TerminalKeyInputEvent
    ) {
        self.hadMarkedText = hadMarkedText
        self.hasMarkedText = hasMarkedText
        self.textInputConsumed = textInputConsumed
        self.textInputCommandPerformed = textInputCommandPerformed
        self.committedText = committedText
        self.event = event
    }
}
