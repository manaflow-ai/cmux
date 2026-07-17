import Foundation

extension GitDiffService {
    /// Runs blocking Git work off the caller's executor and propagates task
    /// cancellation into any subprocess that is currently waiting on kernel
    /// events.
    ///
    /// - Parameter operation: Synchronous Git work performed with a service
    ///   scoped to this cancellable operation.
    /// - Returns: The operation's result.
    public func runCancellable<Result: Sendable>(
        cancelledResult: @escaping @Sendable () -> Result,
        timedOutResult: @escaping @Sendable () -> Result,
        _ operation: @escaping @Sendable (GitDiffService) -> Result
    ) async -> Result {
        let cancellationSignal = GitProcessCancellationSignal()
        let deadline = GitDiffOperationDeadline(timeoutSeconds: operationDeadlineSeconds)
        return await withTaskCancellationHandler {
            let admission = GitDiffBlockingWorkAdmission.shared
            guard await admission.acquire() else {
                return cancelledResult()
            }
            if Task.isCancelled || cancellationSignal.isCancelled {
                await admission.release()
                return cancelledResult()
            }
            return await GitDiffBlockingWorkExecutor.run {
                if cancellationSignal.isCancelled {
                    return cancelledResult()
                }
                let remainingSeconds = deadline.remainingSeconds
                guard remainingSeconds > 0 else {
                    return timedOutResult()
                }
                let service = GitDiffService(
                    processRunner: processRunner.withCancellationSignal(cancellationSignal),
                    operationDeadlineSeconds: remainingSeconds
                )
                return operation(service)
            } onComplete: {
                await admission.release()
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
    }
}

private actor GitDiffBlockingWorkAdmission {
    static let shared = GitDiffBlockingWorkAdmission()

    private let maximumRunningOperationCount = 4
    private let maximumWaitingOperationCount = 32
    private var runningOperationCount = 0
    private var waitingOrder: [UUID] = []
    private var waitingContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if runningOperationCount < maximumRunningOperationCount {
            runningOperationCount += 1
            return true
        }
        guard waitingOrder.count < maximumWaitingOperationCount else {
            return false
        }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await waitForSlot(identifier: identifier)
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    func release() {
        if resumeNextWaiter() {
            return
        }
        runningOperationCount = max(0, runningOperationCount - 1)
    }

    private func waitForSlot(identifier: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: false)
                return
            }
            waitingOrder.append(identifier)
            waitingContinuations[identifier] = continuation
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        waitingOrder.removeAll { $0 == identifier }
        waitingContinuations.removeValue(forKey: identifier)?.resume(returning: false)
    }

    private func resumeNextWaiter() -> Bool {
        while !waitingOrder.isEmpty {
            let identifier = waitingOrder.removeFirst()
            if let continuation = waitingContinuations.removeValue(forKey: identifier) {
                continuation.resume(returning: true)
                return true
            }
        }
        return false
    }
}

private enum GitDiffBlockingWorkExecutor {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.cmux.git-diff.blocking-work"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    static func run<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result,
        onComplete: @escaping @Sendable () async -> Void
    ) async -> Result {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                let result = operation()
                Task {
                    await onComplete()
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
