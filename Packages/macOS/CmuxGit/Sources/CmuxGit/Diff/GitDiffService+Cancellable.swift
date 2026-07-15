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
        _ operation: @escaping @Sendable (GitDiffService) -> Result
    ) async -> Result {
        let cancellationSignal = GitProcessCancellationSignal()
        let service = GitDiffService(
            processRunner: processRunner.withCancellationSignal(cancellationSignal),
            operationDeadlineSeconds: operationDeadlineSeconds
        )
        return await withTaskCancellationHandler {
            await GitDiffBlockingWorkExecutor.run {
                operation(service)
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
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
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: operation())
            }
        }
    }
}
