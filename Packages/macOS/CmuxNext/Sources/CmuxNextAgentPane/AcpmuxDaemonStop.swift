import CmuxNextCompat
import Darwin
import Foundation
import os

/// The person's "Restart agent service" (the pane's waiting line, ``AcpmuxHost/restartStuckAcpmux(sessionId:)``):
/// asks this app's own acpmux daemon to stop (SIGTERM) so the pane's next handshake starts a new
/// one, which adopts the agent hosts and loads every session from disk. A person decides it, never
/// a timer (rule R5): a daemon that answers late is not stopped by the app on its own.
///
/// SIGTERM only, never SIGKILL. acpmux appends each session's event records with a plain write
/// (store.rs `append`) and repairs no torn last line when it reopens the log (`open_writer`), so a
/// SIGKILL in the middle of a write could tear a record, and the next record would be glued onto it
/// and lost too. On SIGTERM acpmux ends its own way. The waiting lookup ends at that exit (its
/// connection closes); a daemon that does not exit keeps running, and the person can press again.
///
/// Only a pid that is this home's (`daemon.pid` in the home), runs `acpmux` (or the bundle's `cmux`)
/// and is the process listening on the home's socket (`LOCAL_PEERPID`) is ever signalled. That
/// process is known by its pid and start time and its audit token (``Daemon``), read before those
/// checks and again after them and before the signal: a pid the kernel gave to another process
/// meanwhile is never signalled (``signal(_:_:process:)`` puts a kernel exit watch on the process
/// before that check, and the signal goes by audit token, so the kernel refuses it once the pid
/// names another process). This is the identity check of the removed AcpmuxUnresponsiveWatch (#25379).
nonisolated final class AcpmuxDaemonStop: Sendable {
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

    /// The process `pid` names now, nil when none (``kernelProcess(pid:)``; a stand-in in tests).
    private let process: @Sendable (Int32) -> Daemon?

    init(process: @escaping @Sendable (Int32) -> Daemon? = AcpmuxDaemonStop.kernelProcess(pid:)) {
        self.process = process
    }

    /// Asks `environment`'s own daemon to stop for a person who asked. True when SIGTERM went to it
    /// (the waiting lookup ends at its exit, and the next handshake starts a new one); false when no
    /// daemon of this home runs or it is not this home's by every check above.
    @concurrent func restart(_ environment: AcpmuxEnvironment) async -> Bool {
        guard let daemon = await daemon(environment) else { return false }
        let pid = daemon.pid
        let home = environment.home.standardizedFileURL.path
        // The cause first, then its effect: the lookup that the exit ends writes its own line.
        Self.logger.error("acpmux \(pid) of home=\(home, privacy: .public): a person asked to restart it; sending SIGTERM")
        AcpmuxFailureLog(logPath: environment.logPath).record(.personRestart, detail: "pid \(pid)")
        return terminate(daemon)
    }

    /// SIGTERM to the process `daemon` names, checked right before it with the exit watch already on
    /// that process. True when sent; false when that process is gone or could not be signalled.
    func terminate(_ daemon: Daemon) -> Bool {
        Self.signal(daemon, SIGTERM, process: process) == nil
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
        guard let text = try? String(blockingContentsOf: file, encoding: .utf8),
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
        guard let text = try? String(blockingContentsOf: file, encoding: .utf8),
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
