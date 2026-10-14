import CmuxNextAgentPane
import Darwin
public import Foundation

/// Quit, end sessions: this build's Chief home's brain host ends with the
/// other sessions (home-state-ownership.md section 3). Every build has its
/// own Chief home (`ChiefHome`), so a quit never stops another build's
/// Chief. A quit that keeps sessions keeps it running for the next launch.
public nonisolated enum ChiefHostStop {
    /// Sends SIGTERM to the host that holds the Chief home's lock; returns
    /// its pid, or nil when none runs. The pid comes from the lock's text and
    /// counts only while the lock is held and the process is an
    /// `optchat-chief`, so a stale text never names another process.
    @discardableResult
    @concurrent static func stop(home: ChiefHome, isChiefHost: @Sendable (pid_t) -> Bool = ChiefHostStop.isChiefHost) async -> pid_t? {
        guard let pid = runningHostPID(home: home, isChiefHost: isChiefHost), kill(pid, SIGTERM) == 0 else { return nil }
        return pid
    }

    /// The pid of the host that holds the home's lock: the pid in the lock's
    /// text while that process runs an `optchat-chief`. A host writes the
    /// text only after it holds the flock, so a live host named there holds
    /// it; a dead one's stale text names nothing. No lock probe: taking the
    /// flock for an instant can make a host that starts in that instant exit.
    public nonisolated static func runningHostPID(home: ChiefHome, isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost) -> pid_t? {
        let lock = home.root.appendingPathComponent("state/host.lock")
        // concurrency-allow: a small local file read; callers run off the main actor or at a brain exit
        guard let text = try? String(contentsOf: lock, encoding: .utf8),
              let pid = text.split(separator: "\n").first.flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }),
              pid > 1, isChiefHost(pid) else { return nil }
        return pid
    }

    /// Quit, end sessions: the Chief home's host, then its acpmux daemon, so nothing of the Chief outlives the quit
    /// with ppid 1. The Chief owner ends through `ChiefConversationOwner`.
    /// What End Sessions keeps running in the Chief home's acpmux.
    static let endSessionsKeep: AcpmuxQuit.Keep = .nothing

    @concurrent public static func endChiefSessions(home: ChiefHome, bundledBin: URL?) async {
        _ = await stop(home: home)
        let environment = AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bundledBin,
                                                    environment: ["ACPMUX_HOME": home.acpmuxHome.path])
        // The daemon exits (Quit Everything's own end); the Chief's sessions stay on disk.
        _ = await AcpmuxQuit.endAgents(environment, keep: endSessionsKeep)
    }

    /// Whether `pid` runs an `optchat-chief` executable.
    public static func isChiefHost(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/" + HomeBrainHost.bundledChiefName)
    }
}
