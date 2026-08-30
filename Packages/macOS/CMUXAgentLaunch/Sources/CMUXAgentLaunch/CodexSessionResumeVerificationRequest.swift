/// One Codex resume identity and its optional hook-provided rollout path.
public struct CodexSessionResumeVerificationRequest: Equatable, Sendable {
    /// The exact identifier that would be passed to `codex resume`.
    public let sessionId: String
    /// A rollout path captured by the hook, when one was available.
    public let transcriptPath: String?

    /// Creates a Codex durable-state verification request.
    ///
    /// - Parameters:
    ///   - sessionId: The exact Codex session identifier.
    ///   - transcriptPath: An optional hook-provided rollout candidate.
    public init(sessionId: String, transcriptPath: String? = nil) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
    }
}
