public import CmuxAgentReplica

/// Monotonic replica clock used for locally-created send tickets.
public final class AgentSyncReplicaClock: ReplicaClock, @unchecked Sendable {
    // The sync engine and replica stores call this clock from the main actor; the
    // ReplicaClock protocol itself is nonisolated, so the stored tick is narrowed
    // to this escape hatch instead of marking broader engine state unsafe.
    private nonisolated(unsafe) var value: Int

    /// Creates a monotonic replica clock.
    /// - Parameter initialValue: The initial tick value.
    public init(initialValue: Int = 0) {
        self.value = initialValue
    }

    /// Returns and advances the next tick.
    /// - Returns: A monotonic integer tick.
    public nonisolated func tick() -> Int {
        value += 1
        return value
    }
}
