import Foundation
internal import os

private let authPhaseTimeoutCleanupRegistry = AuthPhaseTimeoutCleanupRegistry()

private actor AuthPhaseTimeoutCleanupRegistry {
    private var timedOutOperationIDs: [String: UUID] = [:]

    func hasTimedOutOperation(for phase: AuthPhase) -> Bool {
        timedOutOperationIDs[phase.rawValue] != nil
    }

    func trackTimedOutOperation(for phase: AuthPhase, id: UUID) {
        timedOutOperationIDs[phase.rawValue] = id
    }

    func clearTimedOutOperation(for phase: AuthPhase, id: UUID) {
        guard timedOutOperationIDs[phase.rawValue] == id else { return }
        timedOutOperationIDs[phase.rawValue] = nil
    }
}

private final class AuthPhaseTimeoutState<T: Sendable>: @unchecked Sendable {
    private enum Completion: Sendable {
        case success(T)
        case failure(any Error)
    }

    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var cancelHandler: (@Sendable () -> Void)?
        var completion: Completion?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let completion = state.withLock { state -> Completion? in
            guard let completion = state.completion else {
                state.continuation = continuation
                return nil
            }
            state.continuation = nil
            return completion
        }
        if let completion {
            resume(continuation, with: completion)
        }
    }

    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { state in
            guard state.completion == nil else { return true }
            state.cancelHandler = handler
            return false
        }
        if shouldCancel {
            handler()
        }
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        finish(.success(value))
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
        finish(.failure(error))
    }

    @discardableResult
    func cancel() -> Bool {
        finish(.failure(CancellationError()))
    }

    private func finish(_ completion: Completion) -> Bool {
        let installed = state.withLock { state -> (
            continuation: CheckedContinuation<T, any Error>?,
            cancelHandler: (@Sendable () -> Void)?
        )? in
            guard state.completion == nil else { return nil }
            state.completion = completion
            let continuation = state.continuation
            let cancelHandler = state.cancelHandler
            state.continuation = nil
            state.cancelHandler = nil
            return (continuation, cancelHandler)
        }

        guard let installed else { return false }
        installed.cancelHandler?()
        if let continuation = installed.continuation {
            resume(continuation, with: completion)
        }
        return true
    }

    private func resume(_ continuation: CheckedContinuation<T, any Error>, with completion: Completion) {
        switch completion {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
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
    if await authPhaseTimeoutCleanupRegistry.hasTimedOutOperation(for: phase) {
        log.log("auth.phase=\(phase.rawValue) previous timed-out operation still cleaning up")
        throw AuthError.timedOut
    }
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
                let cleanupID = UUID()
                await authPhaseTimeoutCleanupRegistry.trackTimedOutOperation(
                    for: phase,
                    id: cleanupID
                )
                if state.resume(throwing: AuthError.timedOut) {
                    Task {
                        operationTask.cancel()
                        await operationTask.value
                        await authPhaseTimeoutCleanupRegistry.clearTimedOutOperation(
                            for: phase,
                            id: cleanupID
                        )
                    }
                } else {
                    await authPhaseTimeoutCleanupRegistry.clearTimedOutOperation(
                        for: phase,
                        id: cleanupID
                    )
                }
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
