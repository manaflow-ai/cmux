import CmuxNextWakeups
import Foundation
import os
import Synchronization

/// What the app does with a running daemon of another build after an update
/// (plans/cmux-next/durable-sessions.md section 3).
public enum DaemonVersionDecision: Sendable, Equatable {
    /// Keep the running daemon; the reason is for the log.
    case keep(String)
    /// Hand off: the running daemon (`running` commit) exits, keeping its
    /// terminal hosts, and a daemon of the bundled build (`bundled`) adopts them.
    case restart(running: String, bundled: String)
}

/// One launcher's handoff state: the bundled builds it already handed off
/// to (never twice, so a mismatched version string cannot loop), and the
/// daemon that is exiting for a handoff, which the next `ensure` waits out.
final class DaemonHandoffState: Sendable {
    private struct State {
        var handedOffTo: Set<String> = []
        var exiting: Int32?
    }

    private let state = Mutex(State())

    /// Records a handoff to `bundled` of the daemon `pid`; false when this
    /// launcher already handed off to that build.
    func begin(bundled: String, pid: Int32) -> Bool {
        state.withLock {
            guard $0.handedOffTo.insert(bundled).inserted else { return false }
            $0.exiting = pid
            return true
        }
    }

    func cancel(pid: Int32) {
        state.withLock { if $0.exiting == pid { $0.exiting = nil } }
    }

    func takeExiting() -> Int32? {
        state.withLock { $0.exiting.take() }
    }
}

/// Waits for a process to exit through the kernel's exit event (no polling).
enum ProcessExit {
    /// One wait's once-only completion and its deadline task.
    private final class Once: Sendable {
        let done = Mutex(false)
        func first() -> Bool {
            done.withLock { flag in
                defer { flag = true }
                return !flag
            }
        }
    }

    /// True when `pid` exited within `timeout` (or was already gone).
    static func exitEvent(pid: Int32, within timeout: Duration, clock: any Clock<Duration>) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            let deadline = DemandTimer(owner: "daemon.handoff.exit", clock: clock)
            let queue = DispatchQueue(label: "com.cmuxterm.next.daemon.exit.\(pid)")
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let finish: @Sendable (Bool) -> Void = { exited in
                guard once.first() else { return }
                source.cancel()
                deadline.cancel()
                continuation.resume(returning: exited)
            }
            // A bounded deadline, not synchronization: a daemon that does
            // not exit is left to `ensure`, which reports it.
            deadline.schedule(after: timeout) { finish(false) }
            source.setEventHandler { finish(true) }
            source.resume()
            // Registered before this check, so an exit between the two is
            // still seen; a process that is already gone gives no event.
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
    }
}

extension DaemonLauncher {
    static func versionDecision(running: String?, bundled: String?) -> DaemonVersionDecision {
        guard let running else { return .keep("running build unknown") }
        guard let bundled else { return .keep("bundled build unknown") }
        return running == bundled ? .keep("same build") : .restart(running: running, bundled: bundled)
    }

    /// After an update the app finds the daemon an older app started: hand
    /// it off to the bundled build so the update reaches it. Terminals keep
    /// running: `shutdown-daemon` without `end_terminals` leaves every
    /// terminal host alive, the connection reconnects through this
    /// launcher's endpoint provider, which waits for the old daemon to exit
    /// and runs `server ensure` from the bundled binary, and the new daemon
    /// adopts the hosts. `bundledCommit` overrides the bundled binary's own
    /// commit (tests).
    public func handOffIfStale(identity: DaemonIdentity, using connection: DaemonConnection,
                               bundledCommit: String? = nil) async -> DaemonVersionDecision {
        let bundled: String?
        if let bundledCommit {
            bundled = bundledCommit
        } else {
            bundled = try? await bundledBuildCommit()
        }
        let decision = Self.versionDecision(running: identity.buildCommit, bundled: bundled)
        guard case .restart(let running, let target) = decision else { return decision }
        guard handoff.begin(bundled: target, pid: identity.pid) else {
            return .keep("already handed off to \(target)")
        }
        let logger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
        logger.info("daemon \(identity.pid) runs build \(running, privacy: .public); handing off to \(target, privacy: .public)")
        do {
            let reply = try await connection.request(
                ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
            guard reply.accepted != false else {
                handoff.cancel(pid: identity.pid)
                return .keep("the daemon refused the handoff")
            }
        } catch {
            handoff.cancel(pid: identity.pid)
            return .keep("handoff request failed: \(error)")
        }
        return decision
    }
}
