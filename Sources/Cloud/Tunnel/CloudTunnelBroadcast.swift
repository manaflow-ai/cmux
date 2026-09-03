import Foundation

/// Fan-out of one value sequence to any number of `AsyncStream` subscribers.
///
/// Owned by an actor (``CloudTunnelCoordinator``), which is what makes every
/// mutation safe: `subscribe`, `yield`, and `remove` all run under that actor's
/// isolation. A subscriber that stops listening is reported through
/// `onTerminated` (called from whatever task dropped the iterator); the owner
/// hops back onto its isolation and calls ``remove(_:)``, so polling clients
/// that subscribe and leave between yields never accumulate here.
struct CloudTunnelBroadcast<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    /// A new stream that receives `current` first (when given) and then every
    /// later `yield`. `onTerminated` fires once when the subscriber goes away.
    mutating func subscribe(
        current: Value? = nil,
        onTerminated: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { _ in onTerminated(id) }
        if let current {
            continuation.yield(current)
        }
        continuations[id] = continuation
        return stream
    }

    mutating func yield(_ value: Value) {
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) {
                continuations.removeValue(forKey: id)
            }
        }
    }

    /// Drop a subscriber reported through `onTerminated`. Unknown ids are fine.
    mutating func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    var subscriberCount: Int { continuations.count }
}
