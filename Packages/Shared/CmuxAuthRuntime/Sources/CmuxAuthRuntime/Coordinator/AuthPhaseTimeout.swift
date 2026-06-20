import Foundation

private final class AuthPhaseTimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var cancelHandler: (@Sendable () -> Void)?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            handler()
            return
        }
        cancelHandler = handler
        lock.unlock()
    }

    func resume(returning value: T) {
        finish { $0.resume(returning: value) }
    }

    func resume(throwing error: any Error) {
        finish { $0.resume(throwing: error) }
    }

    func cancel() {
        finish { $0.resume(throwing: CancellationError()) }
    }

    private func finish(_ resume: (CheckedContinuation<T, any Error>) -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        let cancelHandler = cancelHandler
        self.continuation = nil
        self.cancelHandler = nil
        lock.unlock()

        guard let continuation else { return }
        cancelHandler?()
        resume(continuation)
    }
}

/// Race `operation` against a `duration` deadline on `clock`.
///
/// Whichever side finishes first cancels the other and resumes the caller
/// immediately. The losing task is not joined, because some Stack SDK calls can
/// ignore cancellation while parked in network/token refresh code; joining
/// those calls would keep user-visible restore/sign-in spinners alive after
/// the deadline had already fired.
///
/// - Parameters:
///   - phase: The phase label for timeout diagnostics.
///   - duration: The deadline.
///   - clock: The clock the deadline sleeps on (virtual in tests).
///   - log: Redacted diagnostics sink; timeouts log the phase and duration.
///   - operation: The bounded work.
/// - Returns: The operation's value when it beats the deadline.
/// - Throws: ``AuthError/timedOut`` at the deadline; otherwise rethrows the
///   operation's error (including `CancellationError` on outer cancellation).
func withAuthPhaseTimeout<T: Sendable>(
    _ phase: AuthPhase,
    duration: Duration,
    clock: any Clock<Duration>,
    log: AuthDebugLog,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let state = AuthPhaseTimeoutState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
            let operationTask = Task {
                do {
                    state.resume(returning: try await operation())
                } catch {
                    state.resume(throwing: error)
                }
            }
            let deadlineTask = Task {
                do {
                    try await clock.sleep(for: duration, tolerance: nil)
                } catch {
                    return
                }
                log.log("auth.phase=\(phase.rawValue) timed out after \(duration)")
                state.resume(throwing: AuthError.timedOut)
            }
            state.setCancelHandler {
                operationTask.cancel()
                deadlineTask.cancel()
            }
        }
    } onCancel: {
        state.cancel()
    }
}
