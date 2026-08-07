/// Owns the approval coordinator's startup and shutdown tasks for one app lifetime.
@MainActor
public final class SudoApprovalRuntime {
    private let coordinator: SudoApprovalCoordinator
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var pendingStartFailureHandler: (@MainActor @Sendable (any Error) -> Void)?
    private var isStopping = false

    /// Creates a lifecycle owner for one approval coordinator.
    ///
    /// - Parameter coordinator: The coordinator started and stopped by this runtime.
    public init(coordinator: SudoApprovalCoordinator) {
        self.coordinator = coordinator
    }

    /// Starts the coordinator, or queues a restart until an active shutdown finishes.
    ///
    /// - Parameter onFailure: A main-actor callback for a broker startup error.
    public func start(
        onFailure: @MainActor @Sendable @escaping (any Error) -> Void
    ) {
        if isStopping || shutdownTask != nil {
            pendingStartFailureHandler = onFailure
            return
        }
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { startupTask = nil }
            do {
                try await coordinator.start()
            } catch {
                guard !Task.isCancelled, !isStopping else { return }
                onFailure(error)
            }
        }
    }

    /// Cancels startup, waits for it to finish, and then stops the broker exactly once.
    public func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isStopping = true
        let startupTask = self.startupTask
        startupTask?.cancel()
        pendingStartFailureHandler = nil
        let coordinator = self.coordinator
        let task = Task {
            await coordinator.stop()
            await startupTask?.value
        }
        shutdownTask = task
        await task.value
        self.startupTask = nil
        shutdownTask = nil
        isStopping = false
        let pendingStartFailureHandler = self.pendingStartFailureHandler
        self.pendingStartFailureHandler = nil
        if let pendingStartFailureHandler {
            start(onFailure: pendingStartFailureHandler)
        }
    }

    /// Cancels local UI work when AppKit has already entered synchronous teardown.
    public func cancelForImmediateTermination() {
        isStopping = true
        pendingStartFailureHandler = nil
        startupTask?.cancel()
        coordinator.cancelForImmediateTermination()
    }
}
