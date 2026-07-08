/// A compact Fleet summary for board fleet pickers.
public struct FleetBoardFleetSummary: Equatable, Sendable, Identifiable {
    /// The Fleet identifier.
    public var id: FleetID

    /// The Fleet display name.
    public var name: String

    /// The repository root associated with the Fleet.
    public var repoRoot: String

    /// Indicates whether the Fleet is dispatching tasks.
    public var isRunning: Bool

    /// Creates a board Fleet summary.
    /// - Parameters:
    ///   - id: The Fleet identifier.
    ///   - name: The Fleet display name.
    ///   - repoRoot: The repository root associated with the Fleet.
    ///   - isRunning: Indicates whether the Fleet is dispatching tasks.
    public init(id: FleetID, name: String, repoRoot: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.repoRoot = repoRoot
        self.isRunning = isRunning
    }
}
