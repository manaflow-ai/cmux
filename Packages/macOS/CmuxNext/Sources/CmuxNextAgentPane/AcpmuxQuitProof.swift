import Darwin
public import Foundation
import Synchronization

/// What proves that Quit Everything ended the local agents (R96 + P2-9).
///
/// The proof is acpmux's own locks, never a pid (a pid can be reused after a
/// crash). The daemon holds an exclusive `flock` on `<home>/daemon.lock` for
/// its whole life (cmux-tui `acpmux/src/daemon.rs` acquire_lock); each agent
/// host holds one on `hosts/<session>.<start_nonce>.live` (agent_host
/// liveness). A shutting-down daemon removes its socket first, so a missing
/// or refusing socket while daemon.lock is held is a shutdown in progress,
/// not "no daemon". The agents ended only when daemon.lock is free and no
/// host lock other than the Home Chief's is held; a lock that cannot be
/// probed counts as held (unknown is never success). `daemon.pid` is only a
/// hint for waiting on the exit and for display.
public nonisolated struct AcpmuxQuitProof {
    public nonisolated init() {}
    public enum LockState: Sendable, Equatable {
        case free, held, unknown
    }

    public struct Facts: Sendable, Equatable {
        public var daemon: LockState
        /// `daemon.pid`, for display and to wait on the exit (a hint only).
        public var daemonPID: Int32?
        /// Sessions whose host lock is held, sorted.
        public var liveHostSessions: [String]
        /// Sessions whose record or lock could not be read, sorted.
        public var unknownHostSessions: [String]

        public init(daemon: LockState, daemonPID: Int32? = nil, liveHostSessions: [String] = [], unknownHostSessions: [String] = []) {
            self.daemon = daemon
            self.daemonPID = daemonPID
            self.liveHostSessions = liveHostSessions
            self.unknownHostSessions = unknownHostSessions
        }
    }

    /// Probes the daemon lock and every host lock of `home`.
    public static func read(home: URL) -> Facts {
        // concurrency-allow: nonisolated; the app calls it only from @concurrent AcpmuxQuit paths, off the main actor
        let pidText = try? String(contentsOf: home.appendingPathComponent("daemon.pid"), encoding: .utf8)
        let hostsDir = home.appendingPathComponent("hosts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: hostsDir, includingPropertiesForKeys: nil)) ?? []
        var live: [String] = []
        var unknown: [String] = []
        for file in files where file.pathExtension == "json" {
            let fallback = file.deletingPathExtension().lastPathComponent
            // concurrency-allow: nonisolated; the app calls it only from @concurrent AcpmuxQuit paths, off the main actor
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = record["session_id"] as? String,
                  let nonce = record["start_nonce"] as? String, isPathComponent(session), isPathComponent(nonce) else {
                unknown.append(fallback)
                continue
            }
            switch lockState(hostsDir.appendingPathComponent("\(session).\(nonce).live")) {
            case .held: live.append(session)
            case .unknown: unknown.append(session)
            case .free: break
            }
        }
        return Facts(daemon: lockState(home.appendingPathComponent("daemon.lock")),
                     daemonPID: pidText.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                     liveHostSessions: live.sorted(), unknownHostSessions: unknown.sorted())
    }

    /// The result from the locks. `daemonExited`: this quit asked the daemon
    /// to end (or waited for a shutdown in progress) and saw daemon.lock free.
    public static func decide(_ facts: Facts, chief: Set<String>, daemonExited: Bool) -> AcpmuxQuit.EndResult {
        guard facts.daemon == .free else { return .shutdownInProgress(pid: facts.daemonPID) }
        let running = Set(facts.liveHostSessions + facts.unknownHostSessions).subtracting(chief).sorted()
        if !running.isEmpty { return .agentsStillRunning(running) }
        return daemonExited ? .ended : .noDaemon
    }

    /// Waits (bounded, no polling) until daemon.lock is free: the kernel exit
    /// event of the pid `daemon.pid` names, then the lock decides. A reused
    /// pid only makes the wait time out; the lock is the proof.
    @concurrent static func waitForDaemonExit(home: URL, within: Duration) async -> Bool {
        let facts = read(home: home)
        if facts.daemon == .free { return true }
        if let pid = facts.daemonPID, pid > 0 {
            _ = await AgentPaneProcessExit.exitEvent(pid: pid, within: within)
        }
        return lockState(home.appendingPathComponent("daemon.lock")) == .free
    }

    /// The Home Chief's sessions as last read from the daemon (census or
    /// endAgents), so the proof does not count the kept Chief host.
    static let knownChief = Mutex<Set<String>>([])

    /// A record field that stays one name inside hosts/ (no "/", no "..").
    static func isPathComponent(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("/") && !text.contains("..")
    }

    /// `flock(LOCK_EX|LOCK_NB)` probe, released at once. A missing file is
    /// free; a lock that cannot be probed is unknown. The probe holds the
    /// exclusive lock for an instant: an acpmux daemon that starts in that
    /// instant fails with "another acpmux daemon holds daemon.lock" and the
    /// app's next findOrStart retries (acpmux's own host probe has the same
    /// window; accepted in the durable review).
    static func lockState(_ url: URL) -> LockState {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .free : .unknown }
        defer { close(fd) }
        // One retry covers an interrupted call (EINTR); anything else decides.
        for _ in 0..<2 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return .free
            }
            if errno == EWOULDBLOCK { return .held }
            if errno != EINTR { return .unknown }
        }
        return .unknown
    }
}
