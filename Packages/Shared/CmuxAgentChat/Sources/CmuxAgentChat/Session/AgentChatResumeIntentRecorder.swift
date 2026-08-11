/// A closure-backed ``AgentChatResumeIntentRecording`` implementation.
public struct AgentChatResumeIntentRecorder: AgentChatResumeIntentRecording {
    private let recordIntent: @MainActor (AgentChatResumeIntent) -> Void

    /// Creates a recorder that forwards each binding to `recordIntent`.
    ///
    /// - Parameter recordIntent: Receives each authoritative restore binding.
    public init(
        recordIntent: @escaping @MainActor (AgentChatResumeIntent) -> Void
    ) {
        self.recordIntent = recordIntent
    }

    /// Forwards one completed restore binding.
    ///
    /// - Parameter intent: The session and terminal identity selected by the restore.
    @MainActor
    public func record(_ intent: AgentChatResumeIntent) {
        recordIntent(intent)
    }
}
