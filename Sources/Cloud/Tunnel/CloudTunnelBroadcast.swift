import Foundation
import os

/// Fan-out of one value sequence to any number of `AsyncStream` subscribers.
///
/// Owned by an actor (``CloudTunnelCoordinator``), which is what makes
/// `subscribe` and `yield` safe: both run under that actor's isolation. A
/// subscriber that stops listening is dropped eagerly: the stream's
/// `onTermination` callback records the id (it runs on whatever task dropped
/// the iterator, so that one set sits behind a lock — the short synchronous
/// compare-and-set carve-out, not domain state), and the next `subscribe` or
/// `yield` removes it. Polling clients that subscribe and leave between yields
/// therefore never grow the table.
final class CloudTunnelBroadcast<Value: Sendable>: @unchecked Sendable {
    // @unchecked: `continuations` is touched only under the owning actor's
    // isolation; `terminated` is the lock-protected callback inbox.
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private let terminated = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// A new stream that receives `current` first (when given) and then every
    /// later `yield`.
    func subscribe(current: Value? = nil) -> AsyncStream<Value> {
        pruneTerminated()
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [terminated] _ in
            terminated.withLock { _ = $0.insert(id) }
        }
        if let current {
            continuation.yield(current)
        }
        continuations[id] = continuation
        return stream
    }

    func yield(_ value: Value) {
        pruneTerminated()
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(value) {
                continuations.removeValue(forKey: id)
            }
        }
    }

    var subscriberCount: Int {
        pruneTerminated()
        return continuations.count
    }

    private func pruneTerminated() {
        let gone = terminated.withLock { set -> Set<UUID> in
            let copy = set
            set.removeAll()
            return copy
        }
        for id in gone {
            continuations.removeValue(forKey: id)
        }
    }
}
