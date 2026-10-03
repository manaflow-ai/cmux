import Foundation

/// Coalesces one remote terminal projection per key while keeping individual
/// callers cancellable. The projection itself remains owned by the registry;
/// cancelling one waiter must not cancel a mutation shared by other panes.
@MainActor
final class CloudTerminalProjectionTask<Value: Sendable> {
    let token = UUID()

    private let operationTask: Task<Value, Error>
    private var completed: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    init(operation: @escaping @MainActor () async throws -> Value) {
        let operationTask = Task { @MainActor in
            try await operation()
        }
        self.operationTask = operationTask
        Task { @MainActor [weak self] in
            do {
                let value = try await operationTask.value
                self?.finish(.success(value))
            } catch {
                self?.finish(.failure(error))
            }
        }
    }

    /// Waits for this projection without allowing cancellation to strand the
    /// caller behind an unstructured `Task.value` await.
    func wait() async throws -> Value {
        let waiterID = UUID()
        let value = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            if let completed {
                return try completed.get()
            }
            return try await withCheckedThrowingContinuation { continuation in
                if let completed {
                    continuation.resume(with: completed)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[waiterID] = continuation
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        })
        // Completion can win the actor hop from onCancel. Do not let a
        // cancelled attachment adopt the value after its waiter was resumed.
        try Task.checkCancellation()
        return value
    }

    /// Used only by registry cleanup. Unlike `wait`, this deliberately remains
    /// attached to the underlying operation until it has actually unwound.
    func operationValue() async throws -> Value {
        try await operationTask.value
    }

    func cancel() {
        operationTask.cancel()
        finish(.failure(CancellationError()))
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Value, Error>) {
        guard completed == nil else { return }
        completed = result
        let waiters = self.waiters
        self.waiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(with: result)
        }
    }
}

/// Owns keyed projection tasks and ignores late completion from an entry that
/// was removed during transport teardown and replaced by a fresh retry.
@MainActor
final class CloudTerminalProjectionRegistry<Value: Sendable> {
    private struct Entry {
        let token: UUID
        let task: CloudTerminalProjectionTask<Value>
        let cleanupTask: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    func contains(_ key: String) -> Bool { entries[key] != nil }

    func value(
        for key: String,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let entry: Entry
        if let current = entries[key] {
            entry = current
        } else {
            let task = CloudTerminalProjectionTask(operation: operation)
            let token = task.token
            let cleanupTask = Task { @MainActor [weak self] in
                _ = try? await task.operationValue()
                self?.remove(key: key, token: token)
            }
            let created = Entry(token: token, task: task, cleanupTask: cleanupTask)
            entries[key] = created
            entry = created
        }
        return try await entry.task.wait()
    }

    /// Cancels waiters immediately and returns the drain of the retired operations.
    /// A caller can join this before releasing transport resources, even if an
    /// operation needs time to unwind after cancellation.
    @discardableResult
    func cancelAll() -> Task<Void, Never> {
        let current = Array(entries.values)
        entries.removeAll()
        for entry in current {
            entry.task.cancel()
        }
        return Task { @MainActor in
            for entry in current {
                await entry.cleanupTask.value
            }
        }
    }

    private func remove(key: String, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries.removeValue(forKey: key)
    }
}
