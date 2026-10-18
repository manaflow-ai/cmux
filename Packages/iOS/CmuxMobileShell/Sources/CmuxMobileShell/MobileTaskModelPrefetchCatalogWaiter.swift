internal import CmuxMobileShellModel
internal import Foundation

/// Broadcasts one shared catalog result without retaining a task per consumer.
actor MobileTaskModelPrefetchCatalogWaiter {
    private let task: Task<[MobileTaskAgentProvider: MobileTaskModelListResult], any Error>
    private var completionTask: Task<Void, Never>?
    private var pending: [UUID: MobileTaskModelPrefetchCatalogPendingWaiter] = [:]
    private var canceledWaiterIDs: Set<UUID> = []
    private var completedResults: [MobileTaskAgentProvider: MobileTaskModelListResult]?
    private var didFinish = false

    init(task: Task<[MobileTaskAgentProvider: MobileTaskModelListResult], any Error>) {
        self.task = task
        self.completionTask = nil
    }

    func start() {
        guard completionTask == nil else { return }
        let task = self.task
        completionTask = Task { [weak self, task] in
            let result = try? await task.value
            await self?.finish(result)
        }
    }

    func result(for provider: MobileTaskAgentProvider) async -> MobileTaskModelListResult? {
        let waiterID = UUID()
        if didFinish {
            return completedResults?[provider]
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.register(
                    waiterID: waiterID,
                    provider: provider,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        completedResults = nil
        task.cancel()
        completionTask?.cancel()
        completionTask = nil
        let waiters = pending.values
        pending.removeAll()
        canceledWaiterIDs.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func register(
        waiterID: UUID,
        provider: MobileTaskAgentProvider,
        continuation: CheckedContinuation<MobileTaskModelListResult?, Never>
    ) {
        guard !didFinish else {
            continuation.resume(returning: nil)
            return
        }
        guard canceledWaiterIDs.remove(waiterID) == nil else {
            continuation.resume(returning: nil)
            return
        }
        pending[waiterID] = MobileTaskModelPrefetchCatalogPendingWaiter(
            provider: provider,
            continuation: continuation
        )
    }

    private func cancel(waiterID: UUID) {
        guard let waiter = pending.removeValue(forKey: waiterID) else {
            if !didFinish {
                canceledWaiterIDs.insert(waiterID)
            }
            return
        }
        waiter.continuation.resume(returning: nil)
    }

    private func finish(
        _ results: [MobileTaskAgentProvider: MobileTaskModelListResult]?
    ) {
        guard !didFinish else { return }
        didFinish = true
        completedResults = results
        completionTask = nil
        let waiters = pending.values
        pending.removeAll()
        canceledWaiterIDs.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: results?[waiter.provider])
        }
    }
}
