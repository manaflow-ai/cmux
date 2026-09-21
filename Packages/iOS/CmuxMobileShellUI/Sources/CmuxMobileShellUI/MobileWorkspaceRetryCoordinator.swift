#if os(iOS)

/// Serializes workspace refreshes so a timed-out caller cannot start a second
/// refresh while the first transport operation is still unwinding.
actor MobileWorkspaceRetryCoordinator {
    private var activeOperation: Task<Void, Never>?
    private var activeOperationID: UUID?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        guard activeOperation == nil else {
            return
        }

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
    /// finishes, while releasing the coordinator so the user can start a fresh
    /// attempt. The production refresh observes task cancellation before it
    /// commits a result, and stale completion state is ignored by the row.
    func cancelActive() {
        activeOperation?.cancel()
        activeOperationID = nil
        activeOperation = nil
    }
}
#endif
