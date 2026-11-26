internal import os

/// Serializes the queue handoff and timeout race for an asynchronous PTY
/// close. Only the short state transition is locked; the close RPC itself
/// never runs while the lock is held.
final class RemotePTYAsyncCloseOperationGate: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case running
        case completed
        case timedOut
    }

    // Lock carve-out: the queue callback and timeout task must claim a
    // one-shot continuation synchronously from different executors.
    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    /// Claims the close for the coordinator queue, or reports that the queue
    /// handoff already timed out.
    func begin() -> Bool {
        state.withLock { current in
            guard current == .pending else { return false }
            current = .running
            return true
        }
    }

    /// Marks a running close complete and returns whether its continuation
    /// still needs a result.
    func complete() -> Bool {
        state.withLock { current in
            guard current == .running else { return false }
            current = .completed
            return true
        }
    }

    /// Claims a timeout only when the coordinator queue has not started the
    /// close yet. A late queue callback then observes the timed-out state and
    /// does not invoke the RPC or resume the continuation twice.
    func timeoutBeforeStart() -> Bool {
        state.withLock { current in
            guard current == .pending else { return false }
            current = .timedOut
            return true
        }
    }
}
