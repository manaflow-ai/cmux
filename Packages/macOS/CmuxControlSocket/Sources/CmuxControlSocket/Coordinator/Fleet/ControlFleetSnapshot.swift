/// A read-only summary of one Fleet engine instance.
///
/// The app target exposes this value through ``ControlFleetContext`` and the
/// coordinator converts it to the `fleet.list` / `fleet.status` wire payload.
public struct ControlFleetSnapshot: Sendable, Equatable {
    /// The stable Fleet identifier on the wire.
    public var fleetID: String
    /// The Fleet display name.
    public var name: String
    /// The repository root this Fleet manages.
    public var repoRoot: String
    /// Whether the Fleet is currently running.
    public var isRunning: Bool
    /// Task counts keyed by state; the coordinator writes every state key.
    public var taskCounts: [ControlFleetTaskStateName: Int]

    /// Creates a Fleet summary snapshot.
    ///
    /// - Parameters:
    ///   - fleetID: The stable Fleet identifier on the wire.
    ///   - name: The Fleet display name.
    ///   - repoRoot: The repository root this Fleet manages.
    ///   - isRunning: Whether the Fleet is currently running.
    ///   - taskCounts: Task counts keyed by state.
    public init(
        fleetID: String,
        name: String,
        repoRoot: String,
        isRunning: Bool,
        taskCounts: [ControlFleetTaskStateName: Int]
    ) {
        self.fleetID = fleetID
        self.name = name
        self.repoRoot = repoRoot
        self.isRunning = isRunning
        self.taskCounts = taskCounts
    }
}
