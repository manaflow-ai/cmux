/// A read-only Fleet engine status snapshot.
///
/// Used by `fleet.status` to report the aggregate engine running state and the
/// visible Fleets.
public struct ControlFleetStatusSnapshot: Sendable, Equatable {
    /// Whether the Fleet engine is currently running.
    public var isRunning: Bool
    /// The Fleets visible to the engine.
    public var fleets: [ControlFleetSnapshot]

    /// Creates a Fleet engine status snapshot.
    ///
    /// - Parameters:
    ///   - isRunning: Whether the Fleet engine is currently running.
    ///   - fleets: The Fleets visible to the engine.
    public init(isRunning: Bool, fleets: [ControlFleetSnapshot]) {
        self.isRunning = isRunning
        self.fleets = fleets
    }
}
