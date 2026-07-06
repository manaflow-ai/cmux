/// Stores the configuration for one Fleet loop.
public struct FleetConfig: Equatable, Codable, Sendable {
    /// The stable Fleet identifier.
    public var id: FleetID

    /// The user-visible Fleet name.
    public var name: String

    /// The repository root Fleet provisions task worktrees from.
    public var repoRoot: String

    /// The directory that stores per-task worktrees or plain task directories.
    public var workspaceRoot: String

    /// The shell command template used to launch the agent.
    public var agentCommandTemplate: String

    /// The maximum number of active agent tasks.
    public var maxConcurrentAgents: Int

    /// The maximum number of tasks provisioning at once.
    public var provisioningCap: Int

    /// The supervision limits for retries and stall recovery.
    public var supervision: FleetSupervisionConfig

    /// Creates a Fleet configuration.
    /// - Parameters:
    ///   - id: The stable Fleet identifier.
    ///   - name: The user-visible Fleet name.
    ///   - repoRoot: The repository root Fleet provisions from.
    ///   - workspaceRoot: The root directory for task worktrees.
    ///   - agentCommandTemplate: The shell command template used to launch the agent.
    ///   - maxConcurrentAgents: The maximum number of active agent tasks.
    ///   - provisioningCap: The maximum number of tasks provisioning at once.
    ///   - supervision: The supervision limits for retries and stall recovery.
    public init(
        id: FleetID,
        name: String,
        repoRoot: String,
        workspaceRoot: String,
        agentCommandTemplate: String = "claude {{PROMPT}}",
        maxConcurrentAgents: Int = 3,
        provisioningCap: Int = 2,
        supervision: FleetSupervisionConfig = FleetSupervisionConfig()
    ) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
        self.workspaceRoot = workspaceRoot
        self.agentCommandTemplate = agentCommandTemplate
        self.maxConcurrentAgents = maxConcurrentAgents
        self.provisioningCap = provisioningCap
        self.supervision = supervision
    }
}
