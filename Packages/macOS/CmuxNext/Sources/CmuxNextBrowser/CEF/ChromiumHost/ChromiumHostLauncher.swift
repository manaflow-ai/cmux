import Darwin
import Dispatch
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

/// A started host: its pid and cmux's end of the wire.
nonisolated struct ChromiumHostProcessHandle: Sendable {
    var pid: pid_t
    var fd: Int32
}

/// Starts Chromium host processes; a seam so tests start a stand-in.
nonisolated protocol ChromiumHostLaunching: Sendable {
    /// Starts `executable` with `arguments` and the wire on its fd 3.
    func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle
    /// Waits until `pid` ends. The pid stays a zombie (not reaped), so it is
    /// never reused while its owner may still signal it; ``reap(_:)`` frees it.
    func exit(of pid: pid_t) async -> ChromiumHostExit
    /// Reaps an ended `pid` (after ``exit(of:)`` returned).
    func reap(_ pid: pid_t)
}

/// Starts a host with `posix_spawn`: a stream `socketpair` whose child end
/// is its fd 3, stdin from /dev/null, stdout and stderr as cmux's, and no
/// other descriptor of cmux (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
nonisolated struct ChromiumHostLauncher: ChromiumHostLaunching {
    enum LaunchError: Error, Equatable {
        case socketPair(Int32)
        case spawn(Int32)
    }

    init() {}

    func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw LaunchError.socketPair(errno) }
        let (parentEnd, childEnd) = (pair[0], pair[1])
        _ = fcntl(parentEnd, F_SETFD, FD_CLOEXEC)
        // A write after the host died fails with EPIPE instead of a SIGPIPE.
        var noSigPipe: Int32 = 1
        _ = setsockopt(parentEnd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, childEnd, 3)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        Darwin.close(childEnd)
        guard result == 0 else {
            Darwin.close(parentEnd)
            throw LaunchError.spawn(result)
        }
        return ChromiumHostProcessHandle(pid: pid, fd: parentEnd)
    }

    func exit(of pid: pid_t) async -> ChromiumHostExit {
        await withCheckedContinuation { continuation in
            ChromiumHostExitWatch(pid: pid, continuation: continuation).start()
        }
    }

    func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) < 0, errno == EINTR {}
    }
}

/// One process-exit source: fires once, reads the exit without reaping, resumes once.
private nonisolated final class ChromiumHostExitWatch: @unchecked Sendable { // crash-allow: wraps a DispatchSourceProcess (no async process-exit API for a posix_spawn'ed pid); `source` is read and written only on the serial `queue`, and the continuation resumes once (finish clears `source` first)
    private let pid: pid_t
    private let continuation: CheckedContinuation<ChromiumHostExit, Never>
    private let queue = DispatchQueue(label: "com.cmuxterm.chromium-host.exit")
    private var source: (any DispatchSourceProcess)?

    init(pid: pid_t, continuation: CheckedContinuation<ChromiumHostExit, Never>) {
        self.pid = pid
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            self.source = source
            source.setEventHandler { [self] in finish() }
            source.resume()
            // The process may have ended before the source existed: then no
            // event comes, and this check finds it.
            finish()
        }
    }

    /// Reads the exit if the process ended (WNOHANG: never blocks; WNOWAIT: the
    /// zombie stays until ``ChromiumHostLauncher/reap(_:)``).
    private func finish() {
        guard let source else { return }
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) } while result < 0 && errno == EINTR // wakeup-allow: an EINTR retry of one WNOHANG call on the exit queue, after the exit event; it never waits or polls
        guard result == 0, info.si_pid == pid else { return }  // still running: the exit event comes later
        source.cancel()
        self.source = nil
        continuation.resume(returning: info.si_code == CLD_EXITED
            ? ChromiumHostExit(signal: nil, status: info.si_status)
            : ChromiumHostExit(signal: info.si_status, status: nil))
    }
}
