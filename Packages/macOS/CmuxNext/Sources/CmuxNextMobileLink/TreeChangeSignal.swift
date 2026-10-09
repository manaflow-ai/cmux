/// Fans one "the tree changed" signal out to every `workspaceChanges()`
/// subscriber; each holds at most one pending signal.
actor TreeChangeSignal {
    private var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextID = 0
    private var finished = false

    func subscribe() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !finished else {
            continuation.finish()
            return stream
        }
        let id = nextID
        nextID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    func signal() {
        for continuation in subscribers.values { continuation.yield() }
    }

    func finish() {
        finished = true
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func remove(_ id: Int) {
        subscribers[id] = nil
    }
}
