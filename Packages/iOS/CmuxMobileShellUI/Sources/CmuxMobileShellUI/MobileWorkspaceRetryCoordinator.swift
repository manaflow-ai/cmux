#if os(iOS)

/// Serializes workspace refreshes so a timed-out caller cannot start a second
/// refresh while the first transport operation is still unwinding.
actor MobileWorkspaceRetryCoordinator {
    private var activeOperation: Task<Void, Never>?
    private var activeOperationID: UUID?

    @discardableResult
    func run(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        guard activeOperation == nil else {
            return false
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
        return true
    }

    /// Cancels the active transport task while retaining ownership until it
    /// finishes. A second tap is rejected during that unwind, so refreshes can
    /// never overlap even when cancellation takes time to propagate.
    func cancelActive() {
        activeOperation?.cancel()
    }
}
#endif
