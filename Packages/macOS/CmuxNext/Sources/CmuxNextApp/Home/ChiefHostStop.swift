import Darwin
import Foundation

/// Quit, end sessions: the Chief home's brain host ends with the other
/// sessions (home-state-ownership.md section 3). A quit that keeps sessions
/// keeps it running, so any build reattaches to the same Chief.
nonisolated enum ChiefHostStop {
    /// Sends SIGTERM to the host that holds the Chief home's lock; returns
    /// its pid, or nil when none runs. The pid comes from the lock's text and
    /// counts only while the lock is held and the process is an
    /// `optchat-chief`, so a stale text never names another process.
    @discardableResult
    static func stop(home: ChiefHome, isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost) -> pid_t? {
        let lock = home.root.appendingPathComponent("state/host.lock")
        guard ChiefMigration.lockHeld(at: lock),
              let text = try? String(contentsOf: lock, encoding: .utf8),
              let pid = text.split(separator: "\n").first.flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }),
              pid > 1, isChiefHost(pid), kill(pid, SIGTERM) == 0 else { return nil }
        return pid
    }

    /// Whether `pid` runs an `optchat-chief` executable.
    static func isChiefHost(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/" + HomeBrainHost.bundledChiefName)
    }
}
