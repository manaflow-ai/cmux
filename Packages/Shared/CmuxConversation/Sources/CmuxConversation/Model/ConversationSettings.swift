/// Settings a new conversation starts with.
///
/// A GUI tab stores these before the conversation exists (the backend
/// creates it on the first message) and inherits them from the previous
/// conversation.
public struct ConversationSettings: Hashable, Sendable, Codable {
    /// The agent or harness, such as `claude` or `codex`.
    public var agent: String?
    /// A model identifier understood by that agent.
    public var model: String?
    /// Reasoning effort, when the agent supports it.
    public var effort: String?
    /// The agent's mode, such as `plan`.
    public var mode: String?
    /// Permission policy name, when the backend supports one.
    public var policy: String?
    /// Working directory, for coding agents.
    public var workingDirectory: String?

    /// Creates settings; every field defaults to the backend's default.
    /// - Parameters:
    ///   - agent: Agent or harness.
    ///   - model: Model identifier.
    ///   - effort: Reasoning effort.
    ///   - mode: Agent mode.
    ///   - policy: Permission policy.
    ///   - workingDirectory: Working directory.
    public init(agent: String? = nil, model: String? = nil, effort: String? = nil, mode: String? = nil, policy: String? = nil, workingDirectory: String? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.mode = mode
        self.policy = policy
        self.workingDirectory = workingDirectory
    }
}
