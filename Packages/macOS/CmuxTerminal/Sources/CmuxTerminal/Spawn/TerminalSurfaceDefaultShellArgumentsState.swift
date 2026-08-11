internal import Foundation

actor TerminalSurfaceDefaultShellArgumentsState {
    private var resolvedArguments: [String]?
    private var waiters: [UUID: CheckedContinuation<[String], Never>] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    func publish(_ arguments: [String]) {
        guard resolvedArguments == nil else { return }
        resolvedArguments = arguments
        let continuations = Array(waiters.values)
        waiters.removeAll()
        cancelledWaiterIDs.removeAll()
        let tasks = Array(deadlineTasks.values)
        deadlineTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for continuation in continuations {
            continuation.resume(returning: arguments)
        }
    }

    func value(
        identifier: UUID,
        fallback: [String],
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> [String] {
        if let resolvedArguments {
            return resolvedArguments
        }
        return await withCheckedContinuation { continuation in
            if let resolvedArguments {
                continuation.resume(returning: resolvedArguments)
                return
            }
            if cancelledWaiterIDs.remove(identifier) != nil || Task.isCancelled {
                continuation.resume(returning: fallback)
                return
            }
            waiters[identifier] = continuation
            deadlineTasks[identifier] = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await clock.sleep(for: deadline, tolerance: nil)
                } catch {
                    return
                }
                await self?.resolveWaiter(identifier, with: fallback)
            }
        }
    }

    nonisolated func cancelWaiter(_ identifier: UUID, with fallback: [String]) {
        Task {
            await self.recordCancellation(identifier, with: fallback)
        }
    }

    private func recordCancellation(_ identifier: UUID, with fallback: [String]) {
        guard resolvedArguments == nil else { return }
        guard let continuation = waiters.removeValue(forKey: identifier) else {
            cancelledWaiterIDs.insert(identifier)
            return
        }
        let deadlineTask = deadlineTasks.removeValue(forKey: identifier)
        deadlineTask?.cancel()
        continuation.resume(returning: fallback)
    }

    private func resolveWaiter(_ identifier: UUID, with arguments: [String]) {
        guard let continuation = waiters.removeValue(forKey: identifier) else { return }
        let deadlineTask = deadlineTasks.removeValue(forKey: identifier)
        deadlineTask?.cancel()
        continuation.resume(returning: arguments)
    }
}
