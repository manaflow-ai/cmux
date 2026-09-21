#if os(iOS)

/// Serializes workspace refreshes so a timed-out caller cannot start a second
/// refresh while the first transport operation is still unwinding.
actor MobileWorkspaceRetryCoordinator {
    private var activeOperation: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var cancellationGeneration = 0

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let generation = cancellationGeneration
        if let activeOperation {
            await activeOperation.value
            guard generation == cancellationGeneration else { return }
        }
        guard !Task.isCancelled, generation == cancellationGeneration else { return }

        let operationTask = Task {
            await operation()
        }
        let operationID = UUID()
        activeOperationID = operationID
        activeOperation = operationTask
        await operationTask.value
        if activeOperationID == operationID {
            activeOperationID = nil
            activeOperation = nil
        }
    }

    /// Cancels the active transport task. The task remains owned until it
    /// finishes, so a later retry waits for it instead of overlapping state
    /// mutations. Waiters that were already queued are invalidated by the
    /// generation change.
    func cancelActive() {
        cancellationGeneration += 1
        activeOperation?.cancel()
    }
}
#endif
