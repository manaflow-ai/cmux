import Synchronization

/// Races async work against a deadline without waiting for the loser.
///
/// A task group would wait for a child that ignores cancellation (a
/// continuation parked on another process's reply), turning a deadline into
/// a hang. Here the first of {result, deadline} resumes the caller; the
/// other side is cancelled and its eventual result dropped.
public enum ControlDeadline {
    public static func run<T: Sendable>(
        method: String,
        deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = ControlError.timeout(method, after: max(deadline - .now, .zero))
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                if race.finish(.failure(timeout)) { work.cancel() }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var done = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func begin(_ continuation: CheckedContinuation<T, any Error>) {
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
            let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<T, any Error>?, (@Sendable () -> Void)?) in
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
