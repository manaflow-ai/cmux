import CmuxNextCompat
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Races async work against a deadline without waiting for the loser. Time
/// the main thread spends in Chromium's start moves the deadline out
/// (`MainThreadEngineStart`).
///
/// A task group would wait for a child that ignores cancellation (a
/// continuation parked on another process's reply), turning a deadline into
/// a hang. Here the first of {result, deadline} resumes the caller; the
/// other side is cancelled and its eventual result dropped.
public struct ControlDeadline: Sendable {
    public static let shared = Self()
    public func run<T: Sendable>(
        method: String,
        deadline: ContinuousClock.Instant,
        startsTerminal: Bool = false,
        countingFrom mark: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let limit = max(deadline - .now, .zero)
        let timeout = startsTerminal ? ControlError.terminalStartTimeout(method, after: limit) : ControlError.timeout(method, after: limit)
        // Main-thread time in Chromium's start after `mark` does not count (MainThreadEngineStart).
        let engineStart = MainThreadEngineStart.shared
        let mark = mark ?? engineStart.total
        // A request deadline is flexible and never early (Chromium's kFlexibleNoSooner, base/task/delay_policy.h).
        let tolerance = WakeLeeway.window(delay: limit).tolerance
        let race = Race<T>()
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                // wakeup-allow: deadline of the request, cancelled when the body answers
                do { try await engineStart.waitPast(deadline, countingFrom: mark, tolerance: tolerance) } catch { return }
                if race.finish(.failure(timeout)) { work.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: OnceContinuation<T, any Error>?
            var done = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func begin(_ continuation: OnceContinuation<T, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        /// Registers cleanup; runs it now if the race already ended.
        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.done { return true }
                state.cleanup = cleanup
                return false
            }
            if runNow { cleanup() }
        }

        /// Returns true for the first caller, which resumes the waiter.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            let (continuation, cleanup) = state.withLock { state -> (OnceContinuation<T, any Error>?, (@Sendable () -> Void)?) in
                guard !state.done else { return (nil, nil) }
                state.done = true
                defer {
                    state.continuation = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cleanup)
            }
            guard let continuation else { return false }
            continuation.resume(with: result)
            cleanup?()
            return true
        }
    }
}
