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
/// wedges again after every start is left for a person). That process is known by its pid and
/// start time and its audit token (``Daemon``), read before those checks and again after them and
/// before each signal: a pid the kernel gave to another process meanwhile is never signalled
/// (``signal(_:_:process:)`` puts a kernel exit watch on the process before that check, and the
/// signal goes by audit token, so the kernel refuses it once the pid names another process), and
/// the exit wait is on the process before its SIGTERM, so it never follows the pid to a successor. The
/// `agent.restartUnresponsiveAcpmux` Debug Settings toggle turns it off: read at each missed status
/// call (off ends the streak) and again right before the restart is claimed. Answers count with
/// the toggle off too, so a streak never spans an answer.
nonisolated final class AcpmuxUnresponsiveWatch: Sendable {
    static let shared = AcpmuxUnresponsiveWatch(clock: ContinuousClock())

    /// One process: its pid, its start time (`proc_bsdinfo`) and its audit token (`TASK_AUDIT_TOKEN`).
    /// A pid the kernel gives to another process later has another start time and another pid
    /// version in its token (`val.7`), the one field besides the pid (`val.5`) the kernel checks
    /// before it signals by token.
    struct Daemon: Equatable, Sendable {
        var pid: Int32
        var startSeconds: UInt64
        var startMicroseconds: UInt64
        var token: audit_token_t

        static func == (lhs: Daemon, rhs: Daemon) -> Bool {
            lhs.pid == rhs.pid && lhs.startSeconds == rhs.startSeconds && lhs.startMicroseconds == rhs.startMicroseconds
                && lhs.token.val.5 == rhs.token.val.5 && lhs.token.val.7 == rhs.token.val.7
        }
    }

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
    /// The process `pid` names now, nil when none (``kernelProcess(pid:)``; a stand-in in tests).
    private let process: @Sendable (Int32) -> Daemon?

    private struct Streak {
        /// Which streak this is: a claim names the one that made it due.
        var id: UInt64
        var pid: Int32
        var count: Int
        var first: Duration
        var last: Duration
    }

    private struct State {
        var streaks: [String: Streak] = [:]
        var lastStreak: UInt64 = 0
        var restarted: Set<String> = []
        var restartsPerHome: [String: Int] = [:]
    }

    private let state = Mutex(State())

    init<C: Clock>(clock: C, misses: Int = 3, window: Duration = .seconds(20), streakGap: Duration = .seconds(300),
                   confirm: Duration = .seconds(5), termGrace: Duration = .seconds(10), perLaunch: Int = 3,
                   process: @escaping @Sendable (Int32) -> Daemon? = AcpmuxUnresponsiveWatch.kernelProcess(pid:)) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.process = process
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

    /// A status call to daemon `pid` of `home` missed its deadline. The streak's id when this
    /// miss makes `misses` in a row spanning at least `window`, `pid` was never restarted and
    /// `home` has restarts left in this launch; nil when not.
    func miss(home: String, pid: Int32) -> UInt64? {
        let now = elapsed()
        return state.withLock { state in
            var streak: Streak
            if let current = state.streaks[home], current.pid == pid, now - current.last <= streakGap {
                streak = current
            } else {
                state.lastStreak &+= 1
                streak = Streak(id: state.lastStreak, pid: pid, count: 0, first: now, last: now)
            }
            streak.count += 1
            streak.last = now
            state.streaks[home] = streak
            let due = streak.count >= misses && now - streak.first >= window && !state.restarted.contains("\(home)|\(pid)")
                && state.restartsPerHome[home, default: 0] < perLaunch
            return due ? streak.id : nil
        }
    }

    /// Whether ``miss(home:pid:)`` made a restart due.
    func missed(home: String, pid: Int32) -> Bool { miss(home: home, pid: pid) != nil }

    /// Takes `pid`'s one restart and one of `home`'s for this launch; false when `streak`, the one
    /// that made it due, is no longer `home`'s (the daemon answered meanwhile, even when misses
    /// after that began another streak, or another caller took it) or `home` has none left. A
    /// claim that says no leaves `home`'s current streak as it is.
    func claim(home: String, streak id: UInt64, pid: Int32) -> Bool {
        state.withLock { state in
            guard let streak = state.streaks[home], streak.id == id, streak.pid == pid else { return false }
            state.streaks.removeValue(forKey: home)
            guard state.restartsPerHome[home, default: 0] < perLaunch, state.restarted.insert("\(home)|\(pid)").inserted else { return false }
            state.restartsPerHome[home, default: 0] += 1
            return true
        }
    }

    /// Counts a missed status call to `environment`'s daemon and restarts that daemon when it
    /// is due and `enabled` (the toggle) still says yes right before the claim. With `enabled`
    /// off the miss ends the streak instead. True when the daemon is gone, so the caller starts a
    /// new one.
    @concurrent func restartIfStuck(_ environment: AcpmuxEnvironment, enabled: @Sendable () -> Bool) async -> Bool {
        let home = environment.home.standardizedFileURL.path
        guard enabled() else {
            answered(home: home)
            return false
        }
        guard let daemon = await daemon(environment), let streak = miss(home: home, pid: daemon.pid) else { return false }
        let pid = daemon.pid
        do {
            _ = try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: confirm)
            answered(home: home)
            return false
        } catch is AgentPaneDeadlineExceeded {
            // Still no answer: restart it below.
        } catch {
            return false
        }
        guard enabled() else {
            answered(home: home)
            return false
        }
        guard claim(home: home, streak: streak, pid: pid) else { return false }
        AcpmuxFailureLog(logPath: environment.logPath).record(.unresponsive, detail: "pid \(pid)")
        Self.logger.error("acpmux \(pid) of home=\(home, privacy: .public) missed \(self.misses + 1, privacy: .public) status calls; restarting it")
        return await stop(daemon, grace: termGrace)
    }

    /// SIGTERM, then SIGKILL when `daemon` outlives `grace`. True once it exited. Each signal goes
    /// only to the process `daemon` names, checked right before it with the exit watch already on
    /// that process; a pid that names another process now means `daemon` exited.
    @concurrent func stop(_ daemon: Daemon, grace: Duration) async -> Bool {
        let pid = daemon.pid
        let process = process
        func send(_ signal: Int32) -> Bool? { Self.signal(daemon, signal, process: process) }
        var unsent = false
        let exited = await AgentPaneProcessExit(pid: pid).event(within: grace) {
            let answer = send(SIGTERM)
            unsent = answer != nil
            return answer
        }
        if exited || unsent { return exited }
        Self.logger.error("acpmux \(pid) outlived SIGTERM by \(grace, privacy: .public); sending SIGKILL")
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(5)) { send(SIGKILL) }
    }

    /// Sends `signal` to `daemon`: nil when sent (wait for the exit), else whether it is gone.
    /// A kernel exit watch (kqueue `EVFILT_PROC`) goes on the pid first, registered before
    /// `kevent` returns, and the identity check after it proves the watch is on `daemon` itself;
    /// an exit that watch saw by the moment before the signal means nothing is sent. The signal
    /// goes by `daemon`'s audit token (`proc_signal_with_audittoken`): the kernel looks the pid up,
    /// holds that process and refuses with `ESRCH` unless its pid version is the token's, so
    /// however long this thread stops between the look and the signal (a debugger, say), a pid
    /// handed to another process meanwhile is never signalled. Without a watch (no kqueue), a
    /// look at it (`kevent` fails) or that call (macOS 14.0 and 14.1, ``signalByToken``) nothing is sent.
    static func signal(_ daemon: Daemon, _ signal: Int32, process: (Int32) -> Daemon?) -> Bool? {
        let pid = daemon.pid
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var watch = Darwin.kevent()
        watch.ident = UInt(pid)
        watch.filter = Int16(EVFILT_PROC)
        watch.flags = UInt16(EV_ADD | EV_ENABLE)
        watch.fflags = UInt32(NOTE_EXIT)
        guard kevent(queue, &watch, 1, nil, 0, nil) == 0 else { return errno == ESRCH }
        guard process(pid) == daemon else { return true }
        var seen = Darwin.kevent()
        var now = timespec(tv_sec: 0, tv_nsec: 0)
        let looked = kevent(queue, nil, 0, &seen, 1, &now)
        guard looked == 0 else { return looked > 0 }
        guard let signalByToken = Self.signalByToken else { return false }
        var token = daemon.token
        // libproc returns the error itself (0 when sent), not -1 and errno.
        let failure = signalByToken(&token, signal)
        return failure == 0 ? nil : failure == ESRCH
    }

    /// libproc's `proc_signal_with_audittoken`, looked up at run time: the libproc of macOS 14.0
    /// and 14.1 lacks it (14.2's has it) and the SDK declares it with no availability, so a direct call
    /// would fail to load the app there. Nil where it is missing; looked up at each signal (a restart).
    typealias SignalByToken = @convention(c) (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32
    static var signalByToken: SignalByToken? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_signal_with_audittoken") else { return nil }
        return unsafeBitCast(symbol, to: SignalByToken.self)
    }

    /// The process `pid` names now (its start time from `proc_pidinfo`, its audit token from its
    /// task name port), nil when none or unreadable. The start time is read before the token and
    /// again after it, so both are one process's.
    static func kernelProcess(pid: Int32) -> Daemon? {
        func start() -> (UInt64, UInt64)? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return (info.pbi_start_tvsec, info.pbi_start_tvusec)
        }
        guard pid > 0, let before = start(), let token = auditToken(pid: pid), let after = start(), before == after,
              token.val.5 == UInt32(bitPattern: pid) else { return nil }
        return Daemon(pid: pid, startSeconds: before.0, startMicroseconds: before.1, token: token)
    }

    /// The audit token of the process `pid` names now (`task_name_for_pid`, which a process of the
    /// same user may call, then `TASK_AUDIT_TOKEN` on that name port), nil when unreadable.
    static func auditToken(pid: Int32) -> audit_token_t? {
        var name = mach_port_name_t(MACH_PORT_NULL)
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        return read == KERN_SUCCESS ? token : nil
    }

    /// `environment`'s own daemon (``daemonPID(_:)``), known by its start time read before those
    /// checks and again after them: nil when the pid named another process meanwhile.
    @concurrent func daemon(_ environment: AcpmuxEnvironment) async -> Daemon? {
        let file = environment.home.appendingPathComponent("daemon.pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let before = process(pid), await Self.daemonPID(environment) == pid, process(pid) == before else { return nil }
        return before
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
