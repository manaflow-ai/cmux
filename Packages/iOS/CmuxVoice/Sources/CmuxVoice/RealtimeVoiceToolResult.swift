/// JSON tool output plus whether the current utterance was delivered.
public struct RealtimeVoiceToolResult: Equatable, Sendable {
    /// JSON string returned to the Realtime model.
    public let output: String
    /// Whether at least one terminal received the latest user transcript.
    public let deliveredLatestUtterance: Bool

    /// Creates a tool result.
    /// - Parameters:
    ///   - output: A valid JSON string.
    ///   - deliveredLatestUtterance: Whether delivery occurred.
    public init(output: String, deliveredLatestUtterance: Bool = false) {
        self.output = output
        self.deliveredLatestUtterance = deliveredLatestUtterance
    }
}
