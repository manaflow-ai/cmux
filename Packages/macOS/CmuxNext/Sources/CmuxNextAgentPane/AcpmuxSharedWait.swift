import CmuxNextCompat

/// One caller's wait for a task that many callers share (``AcpmuxHost``'s daemon lookup). The
/// caller's cancel ends only its own wait; the task goes on for the others. A lookup waits for a
/// slow daemon's answer however long it takes, so a caller that gives up (a pane that closed)
/// must be able to stop waiting without stopping the lookup for every pane.
nonisolated final class AcpmuxSharedWait<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, any Error>)
        case ended(Result<Value, any Error>)
    }

    private let state = Mutex(State.idle)

    private init() {}

    /// `task`'s value, or `CancellationError` once the caller's task is cancelled first.
    static func value(of task: Task<Value, any Error>) async throws -> Value {
        let wait = AcpmuxSharedWait()
        // task-owner: hands the shared task's end to this one waiter; ends when that task ends
        Task { wait.finish(await task.result) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait.store($0) }
        } onCancel: {
            wait.finish(.failure(CancellationError()))
        }
    }

    /// The continuation of the wait; an end that came first resumes it at once.
    private func store(_ continuation: CheckedContinuation<Value, any Error>) {
        let ended: Result<Value, any Error>? = state.withLock { state in
            if case .ended(let result) = state { return result }
            state = .waiting(continuation)
            return nil
        }
        if let ended { continuation.resume(with: ended) }
    }

    /// Ends the wait with `result`; only the first end counts.
    private func finish(_ result: Result<Value, any Error>) {
        let waiting: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .ended:
                return nil
            case .waiting(let continuation):
                state = .ended(result)
                return continuation
            case .idle:
                state = .ended(result)
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
