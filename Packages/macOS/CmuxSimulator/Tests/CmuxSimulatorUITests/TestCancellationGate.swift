import Foundation

// The lock protects both fields and removes the continuation before any
// resume, so cancellation and installation cannot double-resume it.
final class TestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isCancelled = false

    func waitUntilCancelled() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumesImmediately = lock.withLock {
                    if isCancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if resumesImmediately { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.isCancelled = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
