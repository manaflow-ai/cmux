/// Inputs for `fleet.create`.
public struct ControlFleetCreateInputs: Sendable, Equatable {
    /// The Fleet display name.
    public var name: String
    /// The repository root this Fleet manages.
    public var repoRoot: String
    /// The optional agent command.
    public var agentCommand: String?
    /// The optional maximum number of concurrent tasks.
    public var maxConcurrent: Int?

    /// Creates `fleet.create` inputs.
    ///
    /// - Parameters:
    ///   - name: The Fleet display name.
    ///   - repoRoot: The repository root this Fleet manages.
    ///   - agentCommand: The optional agent command.
    ///   - maxConcurrent: The optional maximum number of concurrent tasks.
    public init(name: String, repoRoot: String, agentCommand: String?, maxConcurrent: Int?) {
        self.name = name
        self.repoRoot = repoRoot
        self.agentCommand = agentCommand
        self.maxConcurrent = maxConcurrent
    }
}

/// Inputs for `fleet.task.add`.
public struct ControlFleetTaskAddInputs: Sendable, Equatable {
    /// The Fleet that should receive the task.
    public var fleetID: String
    /// The task title.
    public var title: String
    /// The optional task body.
    public var body: String?
    /// The optional scheduling priority.
    public var priority: Int?

    /// Creates `fleet.task.add` inputs.
    ///
    /// - Parameters:
    ///   - fleetID: The Fleet that should receive the task.
    ///   - title: The task title.
    ///   - body: The optional task body.
    ///   - priority: The optional scheduling priority.
    public init(fleetID: String, title: String, body: String?, priority: Int?) {
        self.fleetID = fleetID
        self.title = title
        self.body = body
        self.priority = priority
    }
}
