import CmuxRemoteWire
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "children")

/// Admission and reaping at the synchronous posix_spawn/waitpid boundary.
/// The lock is a short callback compare-and-set; waiting is an AsyncStream, never a main-thread join.
final class RemoteChildLifetime: Sendable {
    /// The one thread that reaps every tracked child.
    static let reaperName = "remote-child-reaper"

    private struct State {
        var accepting = true
        var permanentlyClosed = false
        var starting = 0
        var children: [UUID: ProcessStamp?] = [:]
        var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var accepting: Bool { state.withLock { $0.accepting } }

    func spawn(executable: String, arguments: [String], environment: [String: String], logPath: String) throws -> ChildProcess {
        guard state.withLock({ value in
            guard value.accepting else { return false }
            value.starting += 1
            return true
        }) else { throw CocoaError(.userCancelled) }
        do {
            let child = try ChildProcess.spawn(executable: executable, arguments: arguments, environment: environment, logPath: logPath)
            let stop = state.withLock { value in
                value.starting -= 1
                value.children[child.lifetimeID] = .some(ProcessStamp.of(child.pid))
                return !value.accepting
            }
            // A spawn admitted before the freeze belongs to this host and must also terminate.
            if stop { stopOwnedChildren([child]) }
            return child
        } catch {
            state.withLock { $0.starting -= 1 }
            changed()
            throw error
        }
    }

    /// Called only by the child's sole waitpid owner, after a successful reap.
    func reaped(_ child: ChildProcess) {
        state.withLock { _ = $0.children.removeValue(forKey: child.lifetimeID) }
        changed()
    }

    /// Reaps a tracked child, blocking the calling thread (never the main or reaper thread)
    /// until the shared reaper sees it exit. -1 when waitpid fails.
    func waitForExit(_ child: ChildProcess) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: Int32(-1))
        watch(child) { status in
            result.withLock { $0 = status }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }
    }

    /// Hands one tracked child to the shared kernel exit reaper. `onExit` runs once, on the
    /// reaper's thread, after the gated reap; it must not block.
    func watch(_ child: ChildProcess, onExit: @escaping @Sendable (Int32) -> Void) {
        ChildReaper.shared.watch(ChildReaper.Waiter(lifetime: self, child: child, onExit: onExit))
    }

    /// One nonblocking reap while holding the signal gate. The same gate serializes it with
    /// every owned signal, so a PID cannot be reused between the identity check and `kill`.
    /// nil while the child runs; -1 when waitpid fails (never an exit receipt).
    fileprivate func reap(_ child: ChildProcess) -> Int32? {
        while true {
            let (result, status) = state.withLock { _ -> (pid_t, Int32) in
                var status: Int32 = 0
                return (waitpid(child.pid, &status, WNOHANG), status)
            }
            if result == child.pid { return status }
            if result == 0 { return nil }
            if errno != EINTR { return -1 }
        }
    }

    /// Permanently closes admission for this host instance. Existing children are stopped by their owners.
    func freeze() { state.withLock { $0.accepting = false; $0.permanentlyClosed = true } }

    /// Prepare claims the spawn boundary only while no child or in-flight spawn exists.
    func claimIdle() -> Bool {
        state.withLock { value in
            guard value.accepting, value.starting == 0, value.children.isEmpty else { return false }
            value.accepting = false
            return true
        }
    }

    func reopenAfterPrepare() { state.withLock { if !$0.permanentlyClosed { $0.accepting = true } } }

    func stopOwnedChildren() { signalOwnedChildren(SIGTERM) }

    /// Signals only the supplied tracked children while holding the reap gate.
    /// A stale ProcessStamp is ignored, so a reused PID is never targeted.
    func stopOwnedChildren(_ children: [ChildProcess]) {
        state.withLock { value in
            for child in children {
                guard let stored = value.children[child.lifetimeID], let stamp = stored,
                      ProcessStamp.of(stamp.pid) == stamp else { continue }
                _ = kill(stamp.pid, SIGTERM)
            }
        }
    }

    /// The host's own exit: SIGTERM, then after `grace` SIGKILL for every stamped child this
    /// host spawned that is still tracked. Whether all of them were reaped by the end of `kill`.
    func terminate(grace: Duration, kill: Duration) async -> Bool {
        stopOwnedChildren()
        if await waitUntilEmpty(timeout: grace) { return true }
        logger.error("remote children outlived SIGTERM by \(String(describing: grace), privacy: .public); sending SIGKILL")
        signalOwnedChildren(SIGKILL)
        return await waitUntilEmpty(timeout: kill)
    }

    /// Only stamped, still-tracked children, under the reap gate.
    private func signalOwnedChildren(_ signal: Int32) {
        state.withLock { value in
            for stored in value.children.values {
                guard let stamp = stored, ProcessStamp.of(stamp.pid) == stamp else { continue }
                _ = Darwin.kill(stamp.pid, signal)
            }
        }
    }

    func waitUntilEmpty(timeout: Duration) async -> Bool {
        let id = UUID()
        let pair = AsyncStream<Bool>.makeStream()
        state.withLock { value in
            value.listeners[id] = pair.continuation
            pair.continuation.yield(value.starting == 0 && value.children.isEmpty)
        }
        defer {
            state.withLock { _ = $0.listeners.removeValue(forKey: id) }
            pair.continuation.finish()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await empty in pair.stream { if empty { return true } }
                return false
            }
            group.addTask {
                // A genuine shutdown deadline, not a polling delay.
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func changed() {
        state.withLock { value in
            let empty = value.starting == 0 && value.children.isEmpty
            for listener in value.listeners.values { listener.yield(empty) }
        }
    }
}

/// One kernel exit reaper for every tracked child of this process: a one-shot kqueue
/// `EVFILT_PROC`/`NOTE_EXIT` watch per child and one thread blocked in `kevent`, so waiting
/// costs no thread per child and no periodic wakeup. Reaping stays behind each lifetime's gate.
private final class ChildReaper: Sendable {
    struct Waiter: Sendable {
        let lifetime: RemoteChildLifetime
        let child: ChildProcess
        let onExit: @Sendable (Int32) -> Void
    }

    static let shared = ChildReaper()
    private let queue = kqueue()
    private let waiting = OSAllocatedUnfairLock(initialState: [pid_t: Waiter]())

    private init() {
        guard queue >= 0 else {
            logger.error("remote child reaper has no kqueue (errno \(errno, privacy: .public)); children stay tracked")
            return
        }
        let thread = Thread { [self] in run() }
        thread.name = RemoteChildLifetime.reaperName
        thread.start()
    }

    /// A PID is reused only after its child was reaped, so a stored waiter for the same PID
    /// belongs to an already reaped child whose own settle still holds it: replacing it is safe.
    func watch(_ waiter: Waiter) {
        waiting.withLock { $0[waiter.child.pid] = waiter }
        settle(waiter.child.pid)
    }

    private func run() {
        var event = Darwin.kevent()
        while true {
            let count = kevent(queue, nil, 0, &event, 1, nil)
            if count == 1, event.filter == Int16(EVFILT_PROC) {
                settle(pid_t(event.ident))
            } else if count < 0, errno != EINTR {
                logger.error("remote child reaper stopped (errno \(errno, privacy: .public)); children stay tracked")
                return
            }
        }
    }

    /// Reaps `pid` if it has exited, else arms its exit watch. Registration fails only while the
    /// child is exiting (ESRCH), and then the reap is retried; any other failure leaves it tracked.
    private func settle(_ pid: pid_t) {
        while let waiter = waiting.withLock({ $0[pid] }) {
            if let status = waiter.lifetime.reap(waiter.child) {
                // Once reaped, the PID can belong to a new child whose waiter replaced this one.
                waiting.withLock { stored in
                    if stored[pid]?.child.lifetimeID == waiter.child.lifetimeID { stored[pid] = nil }
                }
                waiter.onExit(status)
                return
            }
            var change = Darwin.kevent()
            change.ident = UInt(pid)
            change.filter = Int16(EVFILT_PROC)
            change.flags = UInt16(EV_ADD | EV_ONESHOT)
            change.fflags = UInt32(NOTE_EXIT)
            if queue >= 0, kevent(queue, &change, 1, nil, 0, nil) == 0 { return }
            guard queue >= 0, errno == ESRCH else {
                logger.error("remote child pid=\(pid, privacy: .public) has no exit watch; it stays tracked")
                return
            }
        }
    }
}
