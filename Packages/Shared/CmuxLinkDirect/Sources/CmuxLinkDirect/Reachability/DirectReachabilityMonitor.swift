import Foundation
import Network
import os

/// Publishes a `DirectPathSnapshot` on every NWPathMonitor update (no
/// polling). The app feeds each new snapshot to `DirectRoutePlanner` and
/// calls `LinkSession.networkDidChange()`.
public final class DirectReachabilityMonitor: DirectRouteProvider {
    private struct State {
        var latest: DirectPathSnapshot?
        var subscribers: [UUID: AsyncStream<DirectPathSnapshot>.Continuation] = [:]
    }

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {
        let state = state
        monitor.pathUpdateHandler = { path in
            let snapshot = DirectPathSnapshot(path)
            let subscribers = state.withLock { state -> [AsyncStream<DirectPathSnapshot>.Continuation] in
                state.latest = snapshot
                return Array(state.subscribers.values)
            }
            for subscriber in subscribers { subscriber.yield(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "cmux.direct.reachability"))
    }

    deinit {
        monitor.cancel()
    }

    public var currentSnapshot: DirectPathSnapshot? { state.withLock { $0.latest } }

    /// The latest snapshot first (when known), then every change.
    public func snapshots() -> AsyncStream<DirectPathSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DirectPathSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let latest = state.withLock { state -> DirectPathSnapshot? in
            state.subscribers[id] = continuation
            return state.latest
        }
        if let latest { continuation.yield(latest) }
        let state = state
        continuation.onTermination = { _ in
            _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}
