#if os(iOS)
import Foundation

/// Owns refresh tasks after a timeout so a cancellation-ignoring transport
/// cannot wedge the empty-state control or accumulate unbounded work.
actor MobileWorkspaceRetryCoordinator {
    private static let maximumAbandonedAttempts = 3
    private var activeAttempt: Attempt?
    private var abandonedAttempts: [UUID: Task<Void, Never>] = [:]

    func start(_ operation: @escaping @Sendable () async -> Void) -> MobileWorkspaceRetryAttempt? {
        guard activeAttempt == nil,
              abandonedAttempts.count < Self.maximumAbandonedAttempts else {
            return nil
        }
        let attempt = MobileWorkspaceRetryAttempt(id: UUID(), task: Task { await operation() })
        activeAttempt = attempt
        Task { [weak self] in
            await attempt.task.value
            await self?.finish(attempt.id)
        }
        return attempt
    }

    /// Cancels the active task and tracks it until it exits. A later retry can
    /// start immediately, with a small cap on abandoned transports.
    func cancel(_ id: UUID) {
        guard activeAttempt?.id == id, let attempt = activeAttempt else { return }
        activeAttempt = nil
        abandonedAttempts[id] = attempt.task
        attempt.task.cancel()
    }

    func cancelActive(_ id: UUID?) {
        guard let id else { return }
        cancel(id)
    }

    private func finish(_ id: UUID) {
        if activeAttempt?.id == id {
            activeAttempt = nil
        }
        abandonedAttempts.removeValue(forKey: id)
    }
}
#endif
