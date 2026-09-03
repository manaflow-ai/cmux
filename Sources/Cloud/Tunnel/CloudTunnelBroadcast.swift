import Foundation

/// Fan-out of one value sequence to any number of `AsyncStream` subscribers.
///
/// Owned by an actor (``CloudTunnelCoordinator``), which is what makes the
/// mutation safe: every `subscribe` and `yield` happens under that actor's
/// isolation. Subscribers that stop listening are dropped on the next yield,
/// so the table never grows past the number of live listeners.
struct CloudTunnelBroadcast<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    /// A new stream that receives `current` first (when given) and then every
    /// later `yield`.
    mutating func subscribe(current: Value? = nil) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .unbounded)
        if let current {
            continuation.yield(current)
        }
        continuations[UUID()] = continuation
        return stream
    }

    mutating func yield(_ value: Value) {
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) {
                continuations.removeValue(forKey: id)
            }
        }
    }

    var subscriberCount: Int { continuations.count }
}
