/// One conversation in a list, before it is opened.
public struct ConversationSummary: Hashable, Sendable, Identifiable {
    /// The conversation.
    public let id: ConversationID
    /// A display name.
    public var name: String
    /// A title (usually from the first message), when known.
    public var title: String?
    /// What its agent is doing.
    public var status: ConversationStatus
    /// The agent or harness running it, such as `claude` or `codex`.
    public var agent: String?
    /// The working directory, for coding agents.
    public var workingDirectory: String?
    /// The last recorded change, in milliseconds since 1970.
    public var updatedAt: UInt64
    /// Whether it changed while no client was looking.
    public var unread: Bool
    /// How many approval requests wait for an answer.
    public var pendingApprovals: Int
    /// How many messages wait in its queue.
    public var queued: Int

    /// Creates a summary.
    /// - Parameters:
    ///   - id: The conversation.
    ///   - name: Display name.
    ///   - title: Title, if known.
    ///   - status: Agent status.
    ///   - agent: Agent name.
    ///   - workingDirectory: Working directory.
    ///   - updatedAt: Last change time in milliseconds.
    ///   - unread: Changed while unwatched.
    ///   - pendingApprovals: Open approval requests.
    ///   - queued: Waiting messages.
    public init(id: ConversationID, name: String, title: String? = nil, status: ConversationStatus, agent: String? = nil, workingDirectory: String? = nil, updatedAt: UInt64 = 0, unread: Bool = false, pendingApprovals: Int = 0, queued: Int = 0) {
        self.id = id
        self.name = name
        self.title = title
        self.status = status
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.unread = unread
        self.pendingApprovals = pendingApprovals
        self.queued = queued
    }
}
