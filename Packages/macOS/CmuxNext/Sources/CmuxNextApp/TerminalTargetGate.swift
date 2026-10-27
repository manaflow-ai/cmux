import CmuxNextDaemon
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The attach target of a terminal view whose terminal is not created yet: the view of a pane
/// Cmd+D shows before the daemon replied (plans/cmux-next/remote-state-ownership.md S3). The
/// view's attach waits here; keys typed meanwhile wait in its attach machine's input queue and
/// reach the terminal in order after the first replay. ``resolve(_:)`` names the daemon's
/// surface once the split's echo arrived; a view closed first cancels the wait.
nonisolated final class TerminalTargetGate: Sendable {
    private typealias Waiter = OnceContinuation<TerminalAttachment.Target?, OnceContinuationError>

    private struct State {
        var target: TerminalAttachment.Target?
        var waiters: [Waiter] = []
        var cancelled = false
    }

    private let state = Mutex(State())

    init() {}

    /// The resolved target; nil when the view closed before it was known (or the gate went away with
    /// the wait open: its waiter ends abandoned).
    func value() async -> TerminalAttachment.Target? {
        try? await withOnceContinuation { (continuation: Waiter) in
            let ready = state.withLock { state -> TerminalAttachment.Target?? in
                if let target = state.target { return .some(target) }
                if state.cancelled { return .some(nil) }
                state.waiters.append(continuation)
                return .none
            }
            if case .some(let target) = ready { continuation.resume(returning: target) }
        }
    }

    /// Names the daemon's terminal; the first call wins.
    func resolve(_ target: TerminalAttachment.Target) {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.target == nil, !state.cancelled else { return [] }
            state.target = target
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: target) }
    }

    /// The view closed before the target was known.
    func cancel() {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.target == nil else { return [] }
            state.cancelled = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    var isResolved: Bool { state.withLock { $0.target != nil } }
}
