/// The monitor-relevant state extracted from one transcript tail.
public struct CodexTranscriptMonitorSnapshot: Sendable, Equatable {
    /// The newest unresolved request for input, if any.
    public let userInput: CodexTranscriptMonitorUserInput?

    /// The current terminal state of the requested turn.
    public let state: CodexTranscriptMonitorState

    /// Creates a monitor snapshot.
    ///
    /// - Parameters:
    ///   - userInput: The newest unresolved request for input.
    ///   - state: The current terminal state.
    public init(userInput: CodexTranscriptMonitorUserInput?, state: CodexTranscriptMonitorState) {
        self.userInput = userInput
        self.state = state
    }
}
