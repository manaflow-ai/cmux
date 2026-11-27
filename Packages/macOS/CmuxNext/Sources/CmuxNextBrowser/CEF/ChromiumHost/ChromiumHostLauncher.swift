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
}

/// Starts a host with `posix_spawn`: one stream `socketpair` per direction
/// (cmux to host on the host's fd 3, host to cmux on its fd 4), stdin from
/// /dev/null, stdout and stderr as cmux's, and no other descriptor of cmux
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
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
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
            let error = errno
            toHost.forEach { _ = Darwin.close($0) }
            throw LaunchError.socketPair(error)
        }
        for fd in [toHost[0], fromHost[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
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
        await withCheckedContinuation { continuation in
            // One blocked thread per host for its lifetime (no async process-exit
            // API for a posix_spawn'ed pid). WNOWAIT keeps the zombie until reap(_:).
            let thread = Thread {
                var info = siginfo_t()
                var result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
                while result < 0 && errno == EINTR { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) }
                guard result == 0 else {
                    continuation.resume(returning: ChromiumHostExit(signal: nil, status: nil))  // not our child: nothing to wait for
                    return
                }
                continuation.resume(returning: info.si_code == CLD_EXITED
                    ? ChromiumHostExit(signal: nil, status: info.si_status)
                    : ChromiumHostExit(signal: info.si_status, status: nil))
            }
            thread.name = "com.cmuxterm.chromium-host.exit"
            thread.start()
        }
    }

    func reap(_ pid: pid_t) {
        var status: Int32 = 0
        var result = waitpid(pid, &status, WNOHANG)
        while result < 0 && errno == EINTR { result = waitpid(pid, &status, WNOHANG) }
    }
}
