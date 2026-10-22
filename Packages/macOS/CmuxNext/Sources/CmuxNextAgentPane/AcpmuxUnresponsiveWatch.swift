import CmuxNextCompat
import Darwin
import Foundation
import os

/// Restarts this app's own acpmux daemon when it is alive but stops answering. Such a daemon
/// still holds `daemon.lock`, so no new one can start, and every chat says acpmux did not answer
/// until someone kills it. Each status call that misses its deadline is a miss; `misses` in a
/// row with no answer between them, spanning at least `window`, then one last ask with the
/// longer `confirm` deadline that also misses, and the daemon gets SIGTERM (a daemon whose
/// runtime still runs detaches its agent hosts), then SIGKILL after `termGrace`. The daemon
/// the caller starts next adopts the agent hosts and loads every session from disk.
///
/// Only a pid that is this home's (`daemon.pid` in the home), runs `acpmux` (or the bundle's `cmux`)
/// and is the process listening on the home's socket (`LOCAL_PEERPID`) is ever signalled, and
/// each pid at most once, and at most `perLaunch` times per home in one app launch (a daemon that
/// wedges again after every start is left for a person). The `agent.restartUnresponsiveAcpmux`
/// Debug Settings toggle turns it off.
nonisolated final class AcpmuxUnresponsiveWatch: Sendable {
    static let shared = AcpmuxUnresponsiveWatch(clock: ContinuousClock())

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    let misses: Int
    let window: Duration
    /// A miss this long after the previous one starts a new streak.
    let streakGap: Duration
    let confirm: Duration
    let termGrace: Duration
    /// Restarts per home in this launch.
    let perLaunch: Int
    /// The clock's time since this watch was made.
    private let elapsed: @Sendable () -> Duration

    private struct Streak {
        var pid: Int32
        var count: Int
        var first: Duration
        var last: Duration
    }

    private struct State {
        var streaks: [String: Streak] = [:]
        var restarted: Set<String> = []
        var restartsPerHome: [String: Int] = [:]
    }

    private let state = Mutex(State())

    init<C: Clock>(clock: C, misses: Int = 3, window: Duration = .seconds(20), streakGap: Duration = .seconds(300),
                   confirm: Duration = .seconds(5), termGrace: Duration = .seconds(10), perLaunch: Int = 3) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.misses = misses
        self.window = window
        self.streakGap = streakGap
        self.confirm = confirm
        self.termGrace = termGrace
        self.perLaunch = perLaunch
    }

    /// `home`'s daemon answered a status call: its streak ends.
    func answered(home: String) {
        _ = state.withLock { $0.streaks.removeValue(forKey: home) }
    }

    /// A status call to daemon `pid` of `home` missed its deadline. True when this miss makes
    /// `misses` in a row spanning at least `window`, `pid` was never restarted and `home` has
    /// restarts left in this launch.
    func missed(home: String, pid: Int32) -> Bool {
        let now = elapsed()
        return state.withLock { state in
            var streak = state.streaks[home] ?? Streak(pid: pid, count: 0, first: now, last: now)
            if streak.pid != pid || now - streak.last > streakGap {
                streak = Streak(pid: pid, count: 0, first: now, last: now)
            }
            streak.count += 1
            streak.last = now
            state.streaks[home] = streak
            return streak.count >= misses && now - streak.first >= window && !state.restarted.contains("\(home)|\(pid)")
                && state.restartsPerHome[home, default: 0] < perLaunch
        }
    }

    /// Takes `pid`'s one restart and one of `home`'s for this launch; false when another caller
    /// already took it or `home` has none left.
    func claim(home: String, pid: Int32) -> Bool {
        state.withLock { state in
            state.streaks.removeValue(forKey: home)
            guard state.restartsPerHome[home, default: 0] < perLaunch, state.restarted.insert("\(home)|\(pid)").inserted else { return false }
            state.restartsPerHome[home, default: 0] += 1
            return true
        }
    }

    /// Counts a missed status call to `environment`'s daemon and restarts that daemon when it
    /// is due. True when the daemon is gone, so the caller starts a new one.
    @concurrent func restartIfStuck(_ environment: AcpmuxEnvironment) async -> Bool {
        let home = environment.home.standardizedFileURL.path
        guard let pid = await Self.daemonPID(environment), missed(home: home, pid: pid) else { return false }
        do {
            _ = try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: confirm)
            answered(home: home)
            return false
        } catch is AgentPaneDeadlineExceeded {
            // Still no answer: restart it below.
        } catch {
            return false
        }
        guard claim(home: home, pid: pid) else { return false }
        AcpmuxFailureLog(logPath: environment.logPath).record(.unresponsive, detail: "pid \(pid)")
        Self.logger.error("acpmux \(pid) of home=\(home, privacy: .public) missed \(self.misses + 1, privacy: .public) status calls; restarting it")
        return await Self.stop(pid: pid, grace: termGrace)
    }

    /// SIGTERM, then SIGKILL when `pid` outlives `grace`. True once it exited.
    @concurrent static func stop(pid: Int32, grace: Duration) async -> Bool {
        guard kill(pid, SIGTERM) == 0 else { return !agentPaneProcessIsRunning(pid) }
        if await AgentPaneProcessExit(pid: pid).event(within: grace) { return true }
        logger.error("acpmux \(pid) outlived SIGTERM by \(grace, privacy: .public); sending SIGKILL")
        guard kill(pid, SIGKILL) == 0 else { return !agentPaneProcessIsRunning(pid) }
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(5))
    }

    /// The pid of `environment`'s own daemon, nil unless `daemon.pid` in its home names a
    /// running process other than this app, whose executable is named `acpmux` or `cmux` (the
    /// bundle's `bin/acpmux` is a symlink to the multi-call `bin/cmux`, and `proc_pidpath`
    /// resolves it), and which is the process listening on the home's socket.
    @concurrent static func daemonPID(_ environment: AcpmuxEnvironment) async -> Int32? {
        let file = environment.home.appendingPathComponent("daemon.pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid(), agentPaneProcessIsRunning(pid),
              let path = AcpmuxVersionHandoff.executablePath(pid: pid),
              ["acpmux", "cmux"].contains(URL(fileURLWithPath: path).lastPathComponent),
              listenerPID(socketPath: environment.socketPath) == pid else { return nil }
        return pid
    }

    /// The pid of the process listening on the unix socket `socketPath` (`LOCAL_PEERPID` of a
    /// connection to it; the kernel takes the connection even when that process never reads it).
    static func listenerPID(socketPath: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: @concurrent callers only; a local unix socket connect.
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 1 ? pid : nil
    }
}
