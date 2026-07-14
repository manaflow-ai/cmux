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
        let task = Task.detached(priority: .utility) {
            operation(service)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            cancellationSignal.cancel()
            task.cancel()
        }
    }
}
