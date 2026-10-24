#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin
import Foundation

/// How a Chromium host process ended.
nonisolated struct ChromiumHostExit: Equatable, Sendable, CustomStringConvertible {
    /// The signal that ended it (SIGKILL, SIGSEGV, SIGTRAP for a CHECK), or nil for an exit.
    var signal: Int32?
    /// The exit status when it exited.
    var status: Int32?

    var description: String {
        if let signal { return "signal \(signal)" }
        return "exit \(status ?? -1)"
    }

    /// The exit statuses of a host that could not start (`kExit*` in
    /// `ChromiumHost/src/chromium_host_wire.h`), with what each means.
    static let startFailures: [Int32: String] = [
        64: "launched without the wire",
        65: "the Chromium framework did not load",
        66: "the Chromium fork is older than the host needs",
        67: "CefInitialize failed",
    ]

    /// Why the host could not start, when it exited with one of
    /// ``startFailures``; nil for a crash, a signal or any other exit. A new
    /// host would fail the same way, so the session does not restart it.
    var startFailure: String? {
        guard signal == nil, let status, let reason = Self.startFailures[status] else { return nil }
        return "could not start (exit \(status)): \(reason)"
    }
}

/// A started host: its pid and cmux's ends of the wire (frames from the host
/// on `readFD`, to it on `writeFD`).
nonisolated struct ChromiumHostProcessHandle: Sendable {
    var pid: pid_t
    var readFD: Int32
    var writeFD: Int32
}

/// Starts Chromium host processes; a seam so tests start a stand-in.
nonisolated protocol ChromiumHostLaunching: Sendable {
    /// Starts `executable` with `arguments`; it reads frames from cmux on its
    /// fd 3 and writes frames to cmux on its fd 4.
    func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle
    /// Waits until `pid` ends. The pid stays a zombie (not reaped), so it is
    /// never reused while its owner may still signal it; ``reap(_:)`` frees it.
    func exit(of pid: pid_t) async -> ChromiumHostExit
    /// Reaps an ended `pid` (after ``exit(of:)`` returned).
    func reap(_ pid: pid_t)
    /// SIGKILL to `pid`, a host this launcher started and nobody reaped yet
    /// (so the pid is still that host's, never a reused one).
    func kill(_ pid: pid_t)
}

/// Starts a host with `posix_spawn`: one stream `socketpair` per direction
/// (cmux to host on the host's fd 3, host to cmux on its fd 4), stdin from
/// /dev/null, stdout and stderr as cmux's, and no other descriptor of cmux
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The host starts with an empty signal mask
/// and every signal at its default action (`POSIX_SPAWN_SETSIGMASK`,
/// `POSIX_SPAWN_SETSIGDEF`), not with the mask of the thread that spawns it or
/// cmux's ignored signals. It gets cmux's environment.
///
/// The four socket descriptors are made close-on-exec right after each
/// `socketpair` returns. macOS has no `SOCK_CLOEXEC`, so a small window
/// remains: another thread of cmux that forks between `socketpair` and
/// `fcntl` without `POSIX_SPAWN_CLOEXEC_DEFAULT` (a `forkpty` terminal) can
/// get a copy of a wire end, and a copy of cmux's write end keeps the host
/// from reading EOF after cmux dies. The host then still ends at
/// ``ChromiumHostFrame/quitLimit`` after a `quit`, but not after cmux dies.
/// The spawn's `dup2` to fds 3 and 4 clears the flag on the host's copies only.
nonisolated struct ChromiumHostLauncher: ChromiumHostLaunching {
    enum LaunchError: Error, Equatable {
        case socketPair(Int32)
        case spawn(Int32)
    }

    init() {}

    func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle {
        var toHost: [Int32] = [-1, -1]
        var fromHost: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0 else { throw LaunchError.socketPair(errno) }
        toHost.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
            let error = errno
            toHost.forEach { _ = Darwin.close($0) }
            throw LaunchError.socketPair(error)
        }
        fromHost.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        for fd in [toHost[0], fromHost[0]] {
            // A write after the host died fails with EPIPE instead of a SIGPIPE.
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, toHost[1], 3)
        posix_spawn_file_actions_adddup2(&actions, fromHost[1], 4)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        Darwin.close(toHost[1])
        Darwin.close(fromHost[1])
        guard result == 0 else {
            Darwin.close(toHost[0])
            Darwin.close(fromHost[0])
            throw LaunchError.spawn(result)
        }
        return ChromiumHostProcessHandle(pid: pid, readFD: fromHost[0], writeFD: toHost[0])
    }

    func exit(of pid: pid_t) async -> ChromiumHostExit {
        if let ended = Self.exited(pid, blocking: false) { return ended }
        return await withCheckedContinuation { continuation in
            // DispatchSource process source: the carve-out for a child's exit (no Foundation async
            // API for a posix_spawn'ed pid); it never reaps, so the zombie stays until reap(_:).
            // userInitiated: the exit restarts the page a person is looking at (the event handler's waitid
            // returns at once once the exit is posted, so it holds this QoS only briefly).
            let queue = DispatchQueue(label: "com.cmuxterm.chromium-host.exit.\(pid)", qos: .userInitiated)
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            // One-shot resume guard (the lock carve-out): the exit event and the check after arming race.
            let done = Mutex(false)
            let finish: @Sendable (ChromiumHostExit) -> Void = { ended in
                guard done.withLock({ done in defer { done = true }; return !done }) else { return }
                source.cancel()
                continuation.resume(returning: ended)
            }
            source.setEventHandler {
                // The exit event can come before the status is collectable; this wait then
                // returns as soon as it is.
                finish(Self.exited(pid, blocking: true) ?? ChromiumHostExit(signal: nil, status: nil))
            }
            source.resume()
            // A host that ended before the source was armed posts no event: it is a zombie now.
            queue.async { if let ended = Self.exited(pid, blocking: false) { finish(ended) } }
        }
    }

    /// The exit of `pid` without reaping it (`WNOWAIT`): nil while it runs
    /// (`blocking` false), or a status-less exit when it is not a child of
    /// this process (nothing to wait for).
    private static func exited(_ pid: pid_t, blocking: Bool) -> ChromiumHostExit? {
        var info = siginfo_t()
        let options = WEXITED | WNOWAIT | (blocking ? 0 : WNOHANG)
        var result = waitid(P_PID, id_t(pid), &info, options)
        while result < 0 && errno == EINTR { result = waitid(P_PID, id_t(pid), &info, options) }
        guard result == 0 else { return ChromiumHostExit(signal: nil, status: nil) }  // not our child
        guard info.si_pid == pid else { return nil }  // WNOHANG: still running
        return info.si_code == CLD_EXITED
            ? ChromiumHostExit(signal: nil, status: info.si_status)
            : ChromiumHostExit(signal: info.si_status, status: nil)
    }

    func reap(_ pid: pid_t) {
        var status: Int32 = 0
        var result = waitpid(pid, &status, WNOHANG)
        while result < 0 && errno == EINTR { result = waitpid(pid, &status, WNOHANG) }
    }

    func kill(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }
}
#endif
