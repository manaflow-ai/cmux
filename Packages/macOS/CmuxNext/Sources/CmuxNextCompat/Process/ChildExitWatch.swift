public import Darwin
public import Dispatch
import os

/// Reaps one child of this process with no thread parked in `waitpid` while it runs: a process-exit source on
/// a serial reap queue, then a `waitpid` that returns at once. Chromium waits for a child on macOS the same way,
/// through a kqueue `EVFILT_PROC` / `NOTE_EXIT` (base/process/kill_mac.cc, `WaitForChildToDie`), never a thread
/// blocked per child. Shell mode's commands, its Tab completions, the acpmux launch shell, the daemon bridge
/// children and the Computer Use helper all reap through it.
///
/// ```swift
/// kill(pid, SIGKILL)
/// ChildExitWatch(pid: pid, queue: reapQueue).start { _ in }   // returns at once; the reap runs on reapQueue
/// ```
public struct ChildExitWatch: Sendable {
    public let pid: pid_t
    /// The reap queue (serial; its label is listed in threading-model.md), at the QoS of whoever waits for the
    /// exit. Several children may share one: each watch cancels only its own source.
    public let queue: DispatchQueue

    /// - Parameters:
    ///   - pid: A child of this process that nobody else waits for.
    ///   - queue: A serial queue; ``start(exited:)`` reaps the child and calls back on it.
    public init(pid: pid_t, queue: DispatchQueue) {
        self.pid = pid
        self.queue = queue
    }

    /// Calls `exited` once, on ``queue``, after the child exited and was reaped, with its wait status; nil when
    /// it is no child of ours or someone else reaped it (ECHILD), so its status is unknown. Returns at once.
    public func start(exited: @escaping @Sendable (Int32?) -> Void) {
        let (pid, queue) = (self.pid, self.queue)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // The handler and the check below run on the same serial queue; the first to reap cancels the source,
        // so the other does nothing.
        source.setEventHandler {
            guard !source.isCancelled else { return }
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
        // SAFETY: waitpid writes one Int32 status into `status`, a local.
        repeat { result = unsafe waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
        if result == 0 { return nil }
        if result == -1 { logFailure(pid, errno) }
        return .some(result == pid ? status : nil)
    }

    /// The wait for a child whose exit event came. The event can come before the kernel makes the status
    /// collectable; this wait then ends as soon as it is.
    private static func collectExited(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        // wakeup-allow: on the reap queue after the exit event, so the status is collectable at once; retried only
        // when a signal interrupts it.
        // SAFETY: waitpid writes one Int32 status into `status`, a local.
        repeat { result = unsafe blockingWaitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        if result == -1 { logFailure(pid, errno) }
        return result == pid ? status : nil
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "child-reap")

    /// ECHILD is expected (someone else reaped the child); any other failure gets a log line.
    private static func logFailure(_ pid: pid_t, _ failure: Int32) {
        guard failure != ECHILD else { return }
        logger.error("child reap failed pid=\(pid, privacy: .public) errno=\(failure, privacy: .public)")
    }
}
