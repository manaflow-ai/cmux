import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

extension CloudAppLinks {
    /// Runs `operation` and stops waiting for it when the caller is
    /// cancelled: the caller gets `CancellationError` at once, the operation
    /// is cancelled and runs to its own end (a daemon request has its
    /// deadline) and its late answer is dropped. For waits that do not see a
    /// cancel themselves.
    nonisolated static func abandoningOnCancel<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        // task-owner: the operation ends by itself (its own deadline); a cancelled caller only stops waiting
        let work = Task { try await operation() }
        return try await withTaskCancellationHandler {
            // Cancellable: the operation is cancelled with the wait (onCancel below), and its late answer is a no-op.
            try await withOnceThrowingContinuation(cancellation: .cancellable) { (answer: OnceContinuation<T, any Error>) in
                // task-owner: hands the operation's end to the wait; ends with the operation
                Task { answer.resume(with: await work.result) }
            }
        } onCancel: {
            work.cancel()
        }
    }
}
