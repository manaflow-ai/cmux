import Darwin
import Foundation

/// Quit, end sessions: the Chief home's brain host ends with the other
/// sessions (home-state-ownership.md section 3). A quit that keeps sessions
/// keeps it running, so any build reattaches to the same Chief.
nonisolated enum ChiefHostStop {
    /// Sends SIGTERM to the host that holds the Chief home's lock; returns
    /// its pid, or nil when none runs (red-test stub).
    @discardableResult
    static func stop(home: ChiefHome, isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost) -> pid_t? {
        nil
    }

    /// Whether `pid` runs an `optchat-chief` executable.
    static func isChiefHost(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/" + HomeBrainHost.bundledChiefName)
    }
}
