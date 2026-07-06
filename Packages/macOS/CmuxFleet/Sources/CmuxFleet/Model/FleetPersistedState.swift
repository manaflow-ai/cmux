/// Stores the on-disk Fleet engine snapshot.
public struct FleetPersistedState: Equatable, Codable, Sendable {
    /// The current persisted-state schema version.
    public static let currentVersion = 1

    /// The persisted-state schema version.
    public var version: Int

    /// The persisted Fleet snapshots.
    public var fleets: [FleetPersistedFleet]

    /// Creates a persisted Fleet engine snapshot.
    /// - Parameters:
    ///   - version: The persisted-state schema version.
    ///   - fleets: The persisted Fleet snapshots.
    public init(version: Int = Self.currentVersion, fleets: [FleetPersistedFleet]) {
        self.version = version
        self.fleets = fleets
    }
}

/// Stores one persisted Fleet runtime snapshot.
public struct FleetPersistedFleet: Equatable, Codable, Sendable {
    /// The Fleet configuration.
    public var config: FleetConfig

    /// Whether the Fleet was running when persisted.
    public var isRunning: Bool

    /// The persisted task snapshots.
    public var tasks: [FleetTask]

    /// Creates a persisted Fleet runtime snapshot.
    /// - Parameters:
    ///   - config: The Fleet configuration.
    ///   - isRunning: Whether the Fleet was running when persisted.
    ///   - tasks: The persisted task snapshots.
    public init(config: FleetConfig, isRunning: Bool, tasks: [FleetTask]) {
        self.config = config
        self.isRunning = isRunning
        self.tasks = tasks
    }
}
