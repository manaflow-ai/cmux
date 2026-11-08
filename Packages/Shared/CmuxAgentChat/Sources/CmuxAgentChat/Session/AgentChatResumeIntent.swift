/// An authoritative binding between a resumed agent chat and its terminal.
public struct AgentChatResumeIntent: Equatable, Sendable {
    /// The provider-owned identifier of the resumed chat session.
    public let sessionID: String

    /// The agent kind that owns the session, such as `codex` or `claude`.
    public let source: String

    /// The cmux terminal surface receiving the resumed session.
    public let surfaceID: String?

    /// The cmux workspace containing the receiving terminal.
    public let workspaceID: String?

    /// The working directory selected for the resumed agent process.
    public let workingDirectory: String?

    /// Creates a binding produced by one structured agent restore.
    ///
    /// - Parameters:
    ///   - sessionID: Provider-owned identifier of the resumed chat session.
    ///   - source: Agent kind that owns the session.
    ///   - surfaceID: cmux terminal surface receiving the session.
    ///   - workspaceID: cmux workspace containing the terminal.
    ///   - workingDirectory: Working directory selected for the resumed process.
    public init(
        sessionID: String,
        source: String,
        surfaceID: String?,
        workspaceID: String?,
        workingDirectory: String?
    ) {
        self.sessionID = sessionID
        self.source = source
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
    }
}
