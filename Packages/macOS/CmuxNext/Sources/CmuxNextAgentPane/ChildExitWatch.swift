import CmuxNextCompat
import Darwin
import Dispatch

/// Reaps one child of this process with no thread parked in `waitpid` while it runs: a process-exit source on
/// the child's own serial queue, then a `waitpid` that returns at once. Chromium waits for a child on macOS the
/// same way, through a kqueue `EVFILT_PROC` / `NOTE_EXIT` (base/process/kill_mac.cc, `WaitForChildToDie`), never
/// a thread blocked per child.
nonisolated struct ChildExitWatch: Sendable {
    let pid: pid_t
    /// The reap queue, named for the child (its label is listed in threading-model.md), at the QoS of whoever
    /// waits for the exit.
    let queue: DispatchQueue

    /// Calls `exited` once, on ``queue``, after the child exited and was reaped, with its wait status; nil when
    /// it is no child of ours or someone else reaped it (ECHILD), so its status is unknown.
    func start(exited: @escaping @Sendable (Int32?) -> Void) {
        let (pid, queue) = (self.pid, self.queue)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // The handler and the check below run on the same serial queue; the first to reap cancels the source,
        // so the other does nothing.
        source.setEventHandler {
            source.cancel()
            exited(Self.collectExited(pid))
        }
        source.resume()
        // A child that exited before the source was armed posts no event: it is a zombie now, and this reaps it.
        queue.async {
            guard !source.isCancelled, let status = Self.poll(pid) else { return }
            source.cancel()
            exited(status)
        }
    }

    /// One non-blocking `waitpid`: nil while the child runs, `.some(status)` once reaped, `.some(nil)` on ECHILD.
    private static func poll(_ pid: pid_t) -> Int32?? {
        var status: Int32 = 0
        var result: pid_t
        // wakeup-allow: one non-blocking poll, retried only when a signal interrupts it.
        repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        if result == 0 { return nil }
        return .some(result == pid ? status : nil)
    }

    /// The wait for a child whose exit event came. The event can come before the kernel makes the status
    /// collectable; this wait then ends as soon as it is.
    private static func collectExited(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        // wakeup-allow: on the reap queue after the exit event, so the status is collectable at once; retried only
        // when a signal interrupts it.
        repeat { result = blockingWaitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        return result == pid ? status : nil
    }
}
