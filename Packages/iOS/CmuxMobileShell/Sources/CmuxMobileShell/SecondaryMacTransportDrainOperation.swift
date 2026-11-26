import Foundation

/// One physical close shared by every waiter on a retired control connection.
/// A timed-out Mac switch may retry the same reservation, but it must never
/// start another transport close or completion watcher for that peer.
@MainActor
final class SecondaryMacTransportDrainOperation {
    let task: Task<Void, Never>
    var completionTask: Task<Void, Never>?
    private var hasCompleted = false
    private var waiters: [UUID: SecondaryMacTransportDrainWaiter] = [:]

    init(task: Task<Void, Never>) {
        self.task = task
    }

    var pendingWaiterCount: Int { waiters.count }

    func wait(nanoseconds: UInt64) async -> Bool {
        guard !hasCompleted else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !hasCompleted else {
                    continuation.resume(returning: true)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await ContinuousClock().sleep(
                            for: .nanoseconds(Int64(clamping: nanoseconds))
                        )
                    } catch {
                        return
                    }
                    self?.resolveWaiter(waiterID, value: false)
                }
                waiters[waiterID] = SecondaryMacTransportDrainWaiter(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveWaiter(waiterID, value: false)
            }
        }
    }

    func finish() {
        guard !hasCompleted else { return }
        hasCompleted = true
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    private func resolveWaiter(_ waiterID: UUID, value: Bool) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: value)
    }
}
