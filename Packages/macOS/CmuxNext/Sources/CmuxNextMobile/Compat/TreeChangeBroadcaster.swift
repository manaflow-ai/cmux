import Synchronization

/// Fans one "tree changed" signal out to every subscriber. Each subscriber
/// buffers at most one pending signal: a burst of daemon deltas becomes one
/// `workspace.updated` per phone.
final class TreeChangeBroadcaster: Sendable {
    private struct State {
        var next = 0
        var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())

    func subscribe() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id: Int? = state.withLock { state in
            guard !state.finished else { return nil }
            defer { state.next += 1 }
            state.subscribers[state.next] = continuation
            return state.next
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func signal() {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for continuation in subscribers { continuation.yield() }
    }

    func finish() {
        let subscribers = state.withLock { state in
            state.finished = true
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for continuation in subscribers { continuation.finish() }
    }
}
