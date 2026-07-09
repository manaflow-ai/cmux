import Foundation

/// Records one replayable replicated mutation with timing metadata.
public struct ReplicaReplayRecord: Codable, Hashable, Sendable {
    /// The deterministic display tick associated with the mutation.
    public let tick: Int
    /// The origin of the mutation.
    public let origin: DeltaOrigin
    /// The replayed mutation.
    public let delta: ReplicaDelta

    /// Creates a replay record.
    /// - Parameters:
    ///   - tick: The deterministic display tick.
    ///   - origin: The mutation origin.
    ///   - delta: The replayed mutation.
    public init(tick: Int, origin: DeltaOrigin, delta: ReplicaDelta) {
        self.tick = tick
        self.origin = origin
        self.delta = delta
    }
}
