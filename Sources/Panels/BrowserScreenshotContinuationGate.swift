import Foundation

/// Delivers one terminal result across continuation-installation races.
@MainActor
final class BrowserScreenshotContinuationGate<Success> {
    private var continuation: CheckedContinuation<Success, Error>?
    private var pendingResult: Result<Success, Error>?
    private(set) var isFinished = false

    /// Installs the awaiting continuation or immediately delivers an early result.
    ///
    /// - Parameter continuation: Continuation owned by the request's async entrypoint.
    /// - Returns: `true` when the request may start its underlying operation.
    @discardableResult
    func install(
        _ continuation: CheckedContinuation<Success, Error>
    ) -> Bool {
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
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
    func finish(_ result: Result<Success, Error>) -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        guard let continuation else {
            pendingResult = result
            return true
        }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}
