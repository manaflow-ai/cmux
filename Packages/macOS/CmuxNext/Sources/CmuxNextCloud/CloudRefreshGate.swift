import Foundation

/// Coalesces triggers waiting for the next read, without joining a read that
/// started before the trigger. Each caller waits for its own batch's result.
@MainActor
public final class CloudRefreshGate {
    @MainActor
    private final class Batch {
        var task: Task<Bool, Never>?
        var queued = true
        var waiters: Set<UUID> = []
    }

    private var tail: Batch?
    private var batches: [UUID: Batch] = [:]

    public init() {}

    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let batch: Batch
        if let tail, tail.queued, tail.task?.isCancelled == false {
            batch = tail
        } else {
            batch = Batch()
            let previous = tail?.task
            let batchID = UUID()
            batches[batchID] = batch
            tail = batch
            // task-owner: batches; cancel() stops every read during service teardown.
            batch.task = Task { @MainActor in
                defer {
                    self.batches.removeValue(forKey: batchID)
                    if self.tail === batch { self.tail = nil }
                }
                if let previous { _ = await previous.value }
                batch.queued = false
                guard !Task.isCancelled else { return false }
                return await operation()
            }
        }
        let ticket = UUID()
        batch.waiters.insert(ticket)
        guard let task = batch.task else { return false }
        defer { batch.waiters.remove(ticket) }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // task-owner: one main-actor cancellation handoff; no recurring work.
            Task { @MainActor in
                batch.waiters.remove(ticket)
                if batch.waiters.isEmpty { batch.task?.cancel() }
            }
        }
        return !Task.isCancelled && result
    }

    /// Keeps the serialization chain until canceled work unwinds, so a restart
    /// cannot overlap an old transport that has not returned from cancellation.
    public func cancel() {
        for batch in batches.values { batch.task?.cancel() }
    }
}
