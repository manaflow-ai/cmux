/// A pending request-for-input extracted from a Codex transcript.
public struct CodexTranscriptMonitorUserInput: Sendable, Equatable {
    /// A stable call identity used to suppress duplicate notifications.
    public let callID: String

    /// The first user-facing question, when Codex supplied one.
    public let question: String?

    /// Creates a request-for-input value.
    ///
    /// - Parameters:
    ///   - callID: A stable call identity.
    ///   - question: The first user-facing question, if present.
    public init(callID: String, question: String?) {
        self.callID = callID
        self.question = question
    }
}
