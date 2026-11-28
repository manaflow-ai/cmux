import Foundation

/// Delivers one terminal result across continuation-installation races.
@MainActor
public final class BrowserScreenshotContinuationGate<Success> {
    public nonisolated init() {}

    private var continuation: CheckedContinuation<Success, any Error>?
    private var pendingResult: Result<Success, any Error>?
    public private(set) var isFinished = false

    /// Installs the awaiting continuation or immediately delivers an early result.
    ///
    /// - Parameter continuation: Continuation owned by the request's async entrypoint.
    /// - Returns: `true` when the request may start its underlying operation.
    @discardableResult
    public func install(
        _ continuation: CheckedContinuation<Success, any Error>
    ) -> Bool {
        if let pendingResult {
            self.pendingResult = nil
            // The gate drops its reference before delivering, so the result has one owner.
            nonisolated(unsafe) let delivered = pendingResult
            continuation.resume(with: delivered)
            return false
        }
        guard !isFinished, self.continuation == nil else {
            // Request owners are single-use; reject accidental reuse without
            // abandoning the new caller's checked continuation.
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        return true
    }

    /// Accepts and delivers the first terminal result.
    ///
    /// - Parameter result: Success or failure produced by cancellation, timeout,
    ///   or the underlying WebKit callback.
    /// - Returns: `true` only for the first terminal result.
    @discardableResult
    public func finish(_ result: Result<Success, any Error>) -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        guard let continuation else {
            pendingResult = result
            return true
        }
        self.continuation = nil
        // Delivered once and never retained after this point.
        nonisolated(unsafe) let delivered = result
        continuation.resume(with: delivered)
        return true
    }
}
