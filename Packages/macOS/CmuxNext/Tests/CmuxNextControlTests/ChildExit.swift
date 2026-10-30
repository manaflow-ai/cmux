import CmuxNextCompat
import Darwin
import Dispatch

/// Awaits one child's exit through a kqueue process source (`NOTE_EXIT`), so a test sees the child end
/// with no polling. A zombie still answers `kill(pid, 0)`, so that check cannot tell "killed" from
/// "running" until the child is reaped; the exit event can.
///
/// Watch the pid from ``ProcessRequest/onLaunch``, right after the spawn, while the child surely runs.
final class ChildExit: Sendable {
    private struct State {
        var source: (any DispatchSourceProcess)?
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let queue = DispatchQueue(label: "test.child-exit", qos: .userInitiated)
    private let state = Mutex(State())

    /// Starts watching `pid`.
    func watch(_ pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.exited = true
                state.source?.cancel()
                state.source = nil
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
        state.withLock { $0.source = source }
        source.activate()
    }

    /// Returns once the watched child has exited.
    func exit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.exited { return true }
                state.waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}
