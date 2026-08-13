#if os(iOS)
import Foundation

/// Serializes push writes and authoritative reads across timeout recovery.
@MainActor
final class MobilePushMutationSequencer {
    private final class Item {
        var continuation: CheckedContinuation<Void, Never>?
    }

    private var queue: [Item] = []
    private var isRunning = false

    /// Queues one operation behind every earlier operation.
    func enqueue<Value>(
        _ operation: @escaping @MainActor () async -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        let item = Item()
        let task = Task { @MainActor in
            await withCheckedContinuation { continuation in
                item.continuation = continuation
                queue.append(item)
                startNextIfNeeded()
            }
            let value = await operation()
            completion(value)
            finish(item)
        }
        return task
    }

    private func startNextIfNeeded() {
        guard !isRunning, let item = queue.first else { return }
        isRunning = true
        item.continuation?.resume()
        item.continuation = nil
    }

    private func finish(_ item: Item) {
        guard queue.first === item else { return }
        queue.removeFirst()
        isRunning = false
        startNextIfNeeded()
    }
}

/// Mutable state for one queued push mutation.
@MainActor
final class MobilePushMutationAttempt {
    let requested: Bool
    var didTimeout = false
    var task: Task<Void, Never>?

    init(requested: Bool) {
        self.requested = requested
    }
}

/// Tracks one authoritative read queued after a timed-out write.
@MainActor
final class MobilePushReconciliationAttempt {
    let requested: Bool
    let generation: Int
    var task: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(requested: Bool, generation: Int) {
        self.requested = requested
        self.generation = generation
    }
}
#endif
