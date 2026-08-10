import Foundation

/// Resolves each refresh waiter when one panel-content revision finishes or is superseded.
@MainActor
final class GlobalSearchPanelCaptureCompletion {
    let panelRevision: UInt64

    private var isFinished = false
    private var waiters: [
        UUID: (
            continuation: CheckedContinuation<Bool, Never>,
            deadline: GlobalSearchPanelCaptureDeadline
        )
    ] = [:]

    init(panelRevision: UInt64) {
        self.panelRevision = panelRevision
    }

    func wait(until deadline: GlobalSearchPanelCaptureDeadline) async -> Bool {
        guard !isFinished, !deadline.hasExpired, !Task.isCancelled else {
            return isFinished && !Task.isCancelled
        }
        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isFinished, !deadline.hasExpired, !Task.isCancelled else {
                    continuation.resume(returning: isFinished && !Task.isCancelled)
                    return
                }
                waiters[waiterID] = (
                    continuation: continuation,
                    deadline: deadline
                )
                guard deadline.addExpirationHandler(
                    id: waiterID,
                    handler: { [weak self] in
                        self?.expireWaiter(waiterID)
                    }
                ) else {
                    waiters[waiterID] = nil
                    continuation.resume(returning: false)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for (waiterID, waiter) in pendingWaiters {
            waiter.deadline.removeExpirationHandler(id: waiterID)
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.deadline.removeExpirationHandler(id: waiterID)
        waiter.continuation.resume(returning: false)
    }

    private func expireWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: false)
    }
}
