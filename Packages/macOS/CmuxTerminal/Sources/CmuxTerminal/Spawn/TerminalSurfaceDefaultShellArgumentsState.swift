internal import Foundation

actor TerminalSurfaceDefaultShellArgumentsState {
    private var resolvedArguments: [String]?
    private var cachedFallbackArguments: [String]?
    private var waiters: [UUID: CheckedContinuation<[String], Never>] = [:]
    private var deadlineTask: Task<Void, Never>?

    var pendingWaiterCount: Int { waiters.count }
    var pendingDeadlineCount: Int { deadlineTask == nil ? 0 : 1 }

    func publish(_ arguments: [String]) {
        guard resolvedArguments == nil else { return }
        resolvedArguments = arguments
        cachedFallbackArguments = nil
        let continuations = Array(waiters.values)
        waiters.removeAll()
        deadlineTask?.cancel()
        deadlineTask = nil
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
        if let cachedFallbackArguments {
            return cachedFallbackArguments
        }
        return await withCheckedContinuation { continuation in
            if let resolvedArguments {
                continuation.resume(returning: resolvedArguments)
                return
            }
            if let cachedFallbackArguments {
                continuation.resume(returning: cachedFallbackArguments)
                return
            }
            if Task.isCancelled {
                continuation.resume(returning: fallback)
                return
            }
            waiters[identifier] = continuation
            if deadlineTask == nil {
                deadlineTask = Task.detached(priority: .utility) { [weak self] in
                    do {
                        try await clock.sleep(for: deadline, tolerance: nil)
                    } catch {
                        return
                    }
                    await self?.deadlineElapsed(with: fallback)
                }
            }
        }
    }

    nonisolated func cancelWaiter(_ identifier: UUID, with fallback: [String]) {
        Task {
            await self.recordCancellation(identifier, with: fallback)
        }
    }

    private func recordCancellation(_ identifier: UUID, with fallback: [String]) {
        guard resolvedArguments == nil, cachedFallbackArguments == nil else { return }
        guard let continuation = waiters.removeValue(forKey: identifier) else { return }
        if waiters.isEmpty {
            deadlineTask?.cancel()
            deadlineTask = nil
        }
        continuation.resume(returning: fallback)
    }

    private func deadlineElapsed(with fallback: [String]) {
        guard resolvedArguments == nil, cachedFallbackArguments == nil else { return }
        cachedFallbackArguments = fallback
        let continuations = Array(waiters.values)
        waiters.removeAll()
        deadlineTask?.cancel()
        deadlineTask = nil
        for continuation in continuations {
            continuation.resume(returning: fallback)
        }
    }
}
