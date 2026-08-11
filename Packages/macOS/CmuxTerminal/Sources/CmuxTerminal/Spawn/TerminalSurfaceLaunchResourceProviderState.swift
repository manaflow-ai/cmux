internal import Foundation

actor TerminalSurfaceLaunchResourceProviderState {
    private var snapshot: TerminalSurfaceLaunchResourceSnapshot?
    private var cachedFallback: TerminalSurfaceLaunchResourceSnapshot?
    private var waiters: [
        UUID: CheckedContinuation<TerminalSurfaceLaunchResourceSnapshot, Never>
    ] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]

    func install(_ snapshot: TerminalSurfaceLaunchResourceSnapshot) {
        self.snapshot = snapshot
        cachedFallback = nil
        let continuations = Array(waiters.values)
        waiters.removeAll()
        let tasks = Array(deadlineTasks.values)
        deadlineTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for continuation in continuations {
            continuation.resume(returning: snapshot)
        }
    }

    func value(
        identifier: UUID
    ) async -> TerminalSurfaceLaunchResourceSnapshot {
        if let snapshot { return snapshot }
        if let cachedFallback { return cachedFallback }
        return await withCheckedContinuation { continuation in
            if let snapshot {
                continuation.resume(returning: snapshot)
            } else if let cachedFallback {
                continuation.resume(returning: cachedFallback)
            } else if Task.isCancelled {
                continuation.resume(returning: .unavailable)
            } else {
                waiters[identifier] = continuation
            }
        }
    }

    func value(
        identifier: UUID,
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> TerminalSurfaceLaunchResourceSnapshot {
        if let snapshot { return snapshot }
        if let cachedFallback { return cachedFallback }
        return await withCheckedContinuation { continuation in
            if let snapshot {
                continuation.resume(returning: snapshot)
                return
            }
            if let cachedFallback {
                continuation.resume(returning: cachedFallback)
                return
            }
            if Task.isCancelled {
                continuation.resume(returning: .unavailable)
                return
            }
            waiters[identifier] = continuation
            deadlineTasks[identifier] = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await clock.sleep(for: deadline, tolerance: nil)
                } catch {
                    return
                }
                await self?.deadlineElapsed()
            }
        }
    }

    nonisolated func cancelWaiter(_ identifier: UUID) {
        Task {
            await recordCancellation(identifier)
        }
    }

    private func recordCancellation(_ identifier: UUID) {
        guard snapshot == nil, cachedFallback == nil else { return }
        guard let continuation = waiters.removeValue(forKey: identifier) else {
            return
        }
        deadlineTasks.removeValue(forKey: identifier)?.cancel()
        continuation.resume(returning: .unavailable)
    }

    private func deadlineElapsed() {
        guard snapshot == nil, cachedFallback == nil else { return }
        let fallback = TerminalSurfaceLaunchResourceSnapshot.unavailable
        cachedFallback = fallback
        let continuations = Array(waiters.values)
        waiters.removeAll()
        let tasks = Array(deadlineTasks.values)
        deadlineTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for continuation in continuations {
            continuation.resume(returning: fallback)
        }
    }

    func current() -> TerminalSurfaceLaunchResourceSnapshot? {
        snapshot
    }
}
