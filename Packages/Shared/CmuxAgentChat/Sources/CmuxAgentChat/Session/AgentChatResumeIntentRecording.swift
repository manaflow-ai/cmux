/// Records authoritative chat-to-terminal bindings produced by agent restores.
public protocol AgentChatResumeIntentRecording {
    /// Records one completed restore binding.
    ///
    /// - Parameter intent: The session and terminal identity selected by the restore.
    @MainActor
    func record(_ intent: AgentChatResumeIntent)
}
