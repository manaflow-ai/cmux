import Foundation

actor AuthPhaseTimeoutRace {
    private var hasWinner = false

    func winOperation() -> Bool {
        win()
    }

    func winTimeout() -> Bool {
        win()
    }

    private func win() -> Bool {
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}

/// Race a prompt-only operation against a `duration` deadline on `clock`.
///
/// Whichever side finishes first cancels the other and resumes the caller
/// immediately. The losing task is not joined, because some Stack SDK calls can
/// ignore cancellation while parked in network/token refresh code; joining
/// those calls would keep user-visible restore/sign-in spinners alive after
/// the deadline had already fired.
///
/// Do not use this helper for phases that can refresh/write credentials or run
/// signed-in side effects. Those phases need coordinator-owned task handles so
/// sign-out can cancel late work and compare-clear stale token writes.
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
    registry: AuthPhaseTimeoutRegistry,
    blocksRetriesWhileTimedOutOperationActive: Bool,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let phaseID = UUID()
    if blocksRetriesWhileTimedOutOperationActive {
        guard await registry.begin(phase, id: phaseID) else {
            log.log("auth.phase=\(phase.rawValue) previous timed-out operation still active")
            throw AuthError.timedOut
        }
    }
    let race = AuthPhaseTimeoutRace()

    return try await withTaskCancellationHandler {
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let operationTask = Task {
                do {
                    let value = try await operation()
                    if blocksRetriesWhileTimedOutOperationActive {
                        await registry.end(phase, id: phaseID)
                    }
                    guard await race.winOperation() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    if blocksRetriesWhileTimedOutOperationActive {
                        await registry.end(phase, id: phaseID)
                    }
                    guard await race.winOperation() else { return }
                    continuation.finish(throwing: error)
                }
            }
            let deadlineTask = Task {
                do {
                    try await clock.sleep(for: duration, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(phase.rawValue) timed out after \(duration)")
                if blocksRetriesWhileTimedOutOperationActive {
                    await registry.markTimedOut(phase, id: phaseID)
                }
                continuation.finish(throwing: AuthError.timedOut)
                operationTask.cancel()
            }
            continuation.onTermination = { _ in
                operationTask.cancel()
                deadlineTask.cancel()
            }
        }

        for try await value in stream {
            return value
        }
        throw CancellationError()
    } onCancel: {
        guard blocksRetriesWhileTimedOutOperationActive else { return }
        Task { await registry.markTimedOut(phase, id: phaseID) }
    }
}
