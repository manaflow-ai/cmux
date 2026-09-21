#if os(iOS)

/// Serializes workspace refreshes so a timed-out caller cannot start a second
/// refresh while the first transport operation is still unwinding.
actor MobileWorkspaceRetryCoordinator {
    private var activeOperation: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let activeOperation {
            await activeOperation.value
        }

        let operationTask = Task {
            await operation()
        }
        activeOperation = operationTask
        await operationTask.value
        activeOperation = nil
    }
}
#endif
