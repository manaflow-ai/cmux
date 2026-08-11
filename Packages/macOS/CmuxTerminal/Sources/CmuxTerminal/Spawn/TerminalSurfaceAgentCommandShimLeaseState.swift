internal import CmuxTerminalCore
internal import Foundation

private enum TerminalSurfaceShimRemovalOutcome: Sendable {
    case success
    case failure(String)
    case timedOut
    case cancelled
}

private actor TerminalSurfaceAgentCommandShimRemovalRequest {
    private var outcome: TerminalSurfaceShimRemovalOutcome?
    private var waiters: [
        UUID: CheckedContinuation<TerminalSurfaceShimRemovalOutcome, Never>
    ] = [:]

    func resolve(_ outcome: TerminalSurfaceShimRemovalOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiters = Array(waiters.values)
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    func resolvedOutcome() -> TerminalSurfaceShimRemovalOutcome? {
        outcome
    }

    func value() async -> TerminalSurfaceShimRemovalOutcome {
        if let outcome { return outcome }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                } else if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.resume(returning: .cancelled)
    }
}

actor TerminalSurfaceAgentCommandShimRemovalLane {
    private var activeDirectoryPath: String?
    private var activeRequest: TerminalSurfaceAgentCommandShimRemovalRequest?
    private var activeWorkerID: UUID?
    private var worker: Task<Void, Never>?

    fileprivate func submit(
        _ shims: TerminalSurfaceAgentCommandShimSet,
        attemptLimit: Int,
        operation:
        @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportFailure:
        @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) async -> TerminalSurfaceAgentCommandShimRemovalRequest {
        precondition(attemptLimit > 0)
        if activeDirectoryPath == shims.directoryPath, let activeRequest {
            return activeRequest
        }
        let request = TerminalSurfaceAgentCommandShimRemovalRequest()
        guard worker == nil else {
            let description = "command shim removal lane is occupied"
            reportFailure(shims, description)
            await request.resolve(.failure(description))
            return request
        }

        let workerID = UUID()
        activeDirectoryPath = shims.directoryPath
        activeRequest = request
        activeWorkerID = workerID
        worker = Task.detached(priority: .utility) { [weak self] in
            var outcome = TerminalSurfaceShimRemovalOutcome.failure(
                "command shim removal made no attempt"
            )
            for _ in 0..<attemptLimit {
                do {
                    try await operation(shims)
                    outcome = .success
                    break
                } catch {
                    outcome = .failure(String(reflecting: error))
                }
            }
            if case let .failure(description) = outcome {
                reportFailure(shims, description)
            }
            await request.resolve(outcome)
            await self?.finish(workerID: workerID)
        }
        return request
    }

    private func finish(workerID: UUID) {
        guard activeWorkerID == workerID else { return }
        activeDirectoryPath = nil
        activeRequest = nil
        activeWorkerID = nil
        worker = nil
    }
}

actor TerminalSurfaceAgentCommandShimLeaseState {
    private var shims: TerminalSurfaceAgentCommandShimSet?
    private var removalRequest: TerminalSurfaceAgentCommandShimRemovalRequest?
    private var removalAttempt: (
        id: UUID,
        task: Task<TerminalSurfaceShimRemovalOutcome, Never>
    )?
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
        let request: TerminalSurfaceAgentCommandShimRemovalRequest
        let shouldWaitForDeadline: Bool
        if let removalRequest {
            request = removalRequest
            shouldWaitForDeadline = await request.resolvedOutcome() != nil
        } else {
            request = await removalLane.submit(
                shims,
                attemptLimit: removalAttemptLimit,
                operation: remove,
                reportFailure: reportRemovalFailure
            )
            removalRequest = request
            shouldWaitForDeadline = true
        }
        guard shouldWaitForDeadline else { return false }

        let attempt: (
            id: UUID,
            task: Task<TerminalSurfaceShimRemovalOutcome, Never>
        )
        if let removalAttempt {
            attempt = removalAttempt
        } else {
            let id = UUID()
            let deadline = removalAttemptTimeout
            let task = Task.detached(priority: .utility) {
                await Self.wait(
                    for: request,
                    deadline: deadline,
                    clock: removalClock
                )
            }
            attempt = (id: id, task: task)
            removalAttempt = attempt
        }

        let outcome = await attempt.task.value
        guard removalAttempt?.id == attempt.id else { return self.shims == nil }
        removalAttempt = nil
        switch outcome {
        case .success:
            self.shims = nil
            removalRequest = nil
            return true
        case .failure:
            removalRequest = nil
            return false
        case .timedOut:
            reportRemovalFailure(
                shims,
                "command shim removal exceeded \(removalAttemptTimeout)"
            )
            return false
        case .cancelled:
            return false
        }
    }

    private nonisolated static func wait(
        for request: TerminalSurfaceAgentCommandShimRemovalRequest,
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> TerminalSurfaceShimRemovalOutcome {
        await withTaskGroup(of: TerminalSurfaceShimRemovalOutcome.self) { group in
            group.addTask { await request.value() }
            group.addTask {
                do {
                    try await clock.sleep(for: deadline, tolerance: nil)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            return outcome
        }
    }
}
