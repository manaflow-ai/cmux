/// Distinguishes task cancellation from a retryable operation error represented by `CancellationError`.
public struct RecoverableCancellationErrorPolicy: Sendable {
    /// Creates the standard cancellation-error policy.
    public init() {}

    /// Returns whether a caught `CancellationError` should publish a failed state.
    ///
    /// - Parameter taskIsCancelled: The catching task's current cancellation state.
    /// - Returns: `false` only for actual Swift task cancellation.
    public func shouldPublishFailure(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }
}
