public import CmuxNextCloud

extension CloudMoveCLI.StartChatPreflightRefusal {
    /// The start card's `cloud_folder_too_big` (webviews cloudStartProgress.ts): the folder, its size and the repositories
    /// inside it to start in instead; no Retry, which could only fail the same way.
    public nonisolated var reply: [String: Any] {
        AgentPaneReply.failure(code: Self.replyCode, message: message, details: details, retryable: false, origin: "native")
    }
}
