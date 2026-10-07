import CmuxMobileWire

/// The snapshot state of `task:<host>` (task.schema.json `TaskStreamState`):
/// the agents this Mac offers and its newest tasks.
public struct MobileTaskStreamState: Hashable, Sendable, Codable {
    /// Tasks kept in the snapshot, newest first.
    public static let taskLimit = 50

    public var agents: [MobileAgent]
    public var tasks: [MobileTask]

    public init(agents: [MobileAgent], tasks: [MobileTask]) {
        self.agents = agents
        self.tasks = tasks
    }

    public func agent(_ id: String) -> MobileAgent? { agents.first { $0.id == id } }

    public func task(_ id: String) -> MobileTask? { tasks.first { $0.id == id } }

    /// Newest first, capped at `taskLimit`.
    var bounded: MobileTaskStreamState {
        MobileTaskStreamState(agents: agents,
                              tasks: Array(tasks.sorted { $0.createdAt > $1.createdAt }.prefix(Self.taskLimit)))
    }

    public var jsonValue: JSONValue {
        get throws { try JSONValue(encoding: self) }
    }
}
