import Darwin
import Foundation

/// Every live browser-carrier child, so `applicationWillTerminate` can end them
/// synchronously. The carrier's own `--exit-with-parent` watch is not enough:
/// on parent exit (or SIGTERM) cmux-tui awaits a remote `CloseWorkspace` over a
/// link whose WireGuard hub the app has just killed, so it never exits and is
/// reparented to launchd. A quitting app cannot await, so it sends SIGKILL; the
/// remote side drops the proxy workspace when the carrier disconnects.
///
/// The app owns one and passes it to its Cloud and SSH link managers; app
/// termination ends every carrier registered in it.
public final class CloudBrowserProxyQuitRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: pid_t] = [:]
    private let sendSignal: @Sendable (pid_t, Int32) -> Void

    public init(sendSignal: @escaping @Sendable (pid_t, Int32) -> Void = { pid, signal in _ = Darwin.kill(pid, signal) }) {
        self.sendSignal = sendSignal
    }

    /// Records a running child. Call `unregister` from its termination handler
    /// so a recycled PID is never signalled.
    public func register(_ token: UUID, pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        processes[token] = pid
        lock.unlock()
    }

    public func unregister(_ token: UUID) {
        lock.lock()
        processes[token] = nil
        lock.unlock()
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }

    /// Kills every registered carrier without awaiting; safe from `applicationWillTerminate`.
    public func terminateAllForAppQuit() {
        lock.lock()
        let pids = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for pid in pids { sendSignal(pid, SIGKILL) }
    }
}
