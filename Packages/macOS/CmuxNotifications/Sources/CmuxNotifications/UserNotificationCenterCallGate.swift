import os

/// Settles one callback/deadline race and prevents timed-out queued work from starting.
final class UserNotificationCenterCallGate<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<
            Result<Value, UserNotificationCenterFailure>,
            Never
        >?
        var timeoutTask: Task<Void, Never>?
    }

    // Safety: the lock protects the only mutable state and is held only for
    // non-blocking compare-and-swap work around continuation settlement.
    private let state: OSAllocatedUnfairLock<State>

    init(
        continuation: CheckedContinuation<
            Result<Value, UserNotificationCenterFailure>,
            Never
        >
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(continuation: continuation, timeoutTask: nil)
        )
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            guard state.continuation != nil else { return true }
            state.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func shouldStart() -> Bool {
        state.withLock { $0.continuation != nil }
    }

    func resolve(_ result: Result<Value, UserNotificationCenterFailure>) {
        typealias Settlement = (
            CheckedContinuation<Result<Value, UserNotificationCenterFailure>, Never>,
            Task<Void, Never>?
        )
        let settlement: Settlement? = state.withLock { state in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            let timeoutTask = state.timeoutTask
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        guard let settlement else { return }
        settlement.1?.cancel()
        settlement.0.resume(returning: result)
    }
}
