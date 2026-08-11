internal import CmuxTerminalCore
internal import Foundation

private enum TerminalSurfaceShimRemovalOutcome: Sendable {
    case success
    case failure(String)
    case timedOut
    case cancelled
}

private struct TerminalSurfaceShimRemovalError: Error, CustomStringConvertible {
    let description: String
    let isTimeout: Bool
}

actor TerminalSurfaceAgentCommandShimRemovalLane {
    private var isOccupied = false

    func claim() -> Bool {
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    func release() {
        isOccupied = false
    }
}

private actor TerminalSurfaceShimRemovalRace {
    private var outcome: TerminalSurfaceShimRemovalOutcome?
    private var waiter: CheckedContinuation<TerminalSurfaceShimRemovalOutcome, Never>?

    func resolve(_ outcome: TerminalSurfaceShimRemovalOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }

    func value() async -> TerminalSurfaceShimRemovalOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }
}

actor TerminalSurfaceAgentCommandShimLeaseState {
    private var shims: TerminalSurfaceAgentCommandShimSet?
    private var removalAttempt: (id: UUID, task: Task<Void, any Error>)?
    private var removalTimedOut = false
    private let removalAttemptLimit: Int
    private let removalAttemptTimeout: Duration
    private let removalLane: TerminalSurfaceAgentCommandShimRemovalLane
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    private let reportRemovalFailure:
        @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void

    var hasOwnedShims: Bool { shims != nil }

    init(
        shims: TerminalSurfaceAgentCommandShimSet,
        removalAttemptLimit: Int,
        removalAttemptTimeout: Duration = .seconds(5),
        removalLane: TerminalSurfaceAgentCommandShimRemovalLane,
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportRemovalFailure:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) {
        precondition(removalAttemptLimit > 0)
        precondition(removalAttemptTimeout > .zero)
        self.shims = shims
        self.removalAttemptLimit = removalAttemptLimit
        self.removalAttemptTimeout = removalAttemptTimeout
        self.removalLane = removalLane
        self.remove = remove
        self.reportRemovalFailure = reportRemovalFailure
    }

    func release(removalClock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        guard let shims else { return true }
        guard !removalTimedOut else { return false }
        let attempt: (id: UUID, task: Task<Void, any Error>)
        if let removalAttempt {
            attempt = removalAttempt
        } else {
            let id = UUID()
            let remove = remove
            let removalAttemptLimit = removalAttemptLimit
            let removalAttemptTimeout = removalAttemptTimeout
            let removalLane = removalLane
            let task = Task.detached(priority: .utility) {
                var lastError: (any Error)?
                for _ in 0..<removalAttemptLimit {
                    do {
                        try await Self.remove(
                            shims,
                            deadline: removalAttemptTimeout,
                            clock: removalClock,
                            removalLane: removalLane,
                            operation: remove
                        )
                        return
                    } catch let error as TerminalSurfaceShimRemovalError
                        where error.isTimeout
                    {
                        throw error
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? CancellationError()
            }
            attempt = (id: id, task: task)
            removalAttempt = attempt
        }

        do {
            try await attempt.task.value
            guard removalAttempt?.id == attempt.id else { return self.shims == nil }
            self.shims = nil
            removalAttempt = nil
            return true
        } catch {
            guard removalAttempt?.id == attempt.id else { return self.shims == nil }
            removalAttempt = nil
            if let removalError = error as? TerminalSurfaceShimRemovalError,
               removalError.isTimeout
            {
                removalTimedOut = true
            }
            reportRemovalFailure(shims, String(reflecting: error))
            return false
        }
    }

    private nonisolated static func remove(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        deadline: Duration,
        clock: any Clock<Duration>,
        removalLane: TerminalSurfaceAgentCommandShimRemovalLane,
        operation: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard await removalLane.claim() else {
            throw TerminalSurfaceShimRemovalError(
                description: "command shim removal lane is occupied",
                isTimeout: false
            )
        }
        do {
            try Task.checkCancellation()
        } catch {
            await removalLane.release()
            throw error
        }

        let race = TerminalSurfaceShimRemovalRace()
        let removalTask = Task.detached(priority: .utility) {
            do {
                try await operation(shims)
                await removalLane.release()
                await race.resolve(.success)
            } catch {
                await removalLane.release()
                await race.resolve(.failure(String(reflecting: error)))
            }
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await clock.sleep(for: deadline, tolerance: nil)
                await race.resolve(.timedOut)
            } catch {
                await race.resolve(.cancelled)
            }
        }
        let outcome = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            removalTask.cancel()
            timeoutTask.cancel()
            Task { await race.resolve(.cancelled) }
        }
        removalTask.cancel()
        timeoutTask.cancel()
        switch outcome {
        case .success:
            return
        case let .failure(description):
            throw TerminalSurfaceShimRemovalError(description: description, isTimeout: false)
        case .timedOut:
            throw TerminalSurfaceShimRemovalError(
                description: "command shim removal exceeded \(deadline)",
                isTimeout: true
            )
        case .cancelled:
            throw CancellationError()
        }
    }
}
