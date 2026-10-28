#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A started host: its pid and cmux's ends of the wire (frames from the host
/// on `readFD`, to it on `writeFD`).
nonisolated struct ChromiumHostProcessHandle: Sendable {
    var pid: pid_t
    var readFD: Int32
    var writeFD: Int32
}

/// Starts Chromium host processes; a seam so tests start a stand-in.
nonisolated protocol ChromiumHostLaunching: Sendable {
    /// Starts `executable` with `arguments` off the caller's thread; it reads frames from cmux on its
    /// fd 3 and writes frames to cmux on its fd 4.
    func launch(executable: URL, arguments: [String]) async throws -> ChromiumHostProcessHandle
    /// Waits until `pid` ends. The pid stays a zombie (not reaped), so it is
    /// never reused while its owner may still signal it; ``reap(_:)`` frees it.
    func exit(of pid: pid_t) async -> ChromiumHostExit
    /// Reaps an ended `pid` (after ``exit(of:)`` returned).
    func reap(_ pid: pid_t)
    /// SIGKILL to `pid`, a host this launcher started and nobody reaped yet
    /// (so the pid is still that host's, never a reused one).
    func kill(_ pid: pid_t)
}

extension ChromiumHostLaunching {
    /// Ends a started host nobody will connect (its session went away during the launch), and frees its
    /// pid and both wire ends.
    func discard(_ handle: ChromiumHostProcessHandle) async {
        Darwin.close(handle.readFD)
        Darwin.close(handle.writeFD)
        kill(handle.pid)
        _ = await exit(of: handle.pid)
        reap(handle.pid)
    }
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

    /// Delivers the exit events of this launcher's hosts (no thread per host). Serial, one per launcher: an
    /// event handler only collects an exit the kernel has posted (`waitid` waits at most until the status is
    /// collectable, which follows the event at once), so hosts never wait on each other for long.
    /// By default userInitiated: the exit restarts the page a person is looking at.
    private let exitQueue: DispatchQueue
    /// The host's spawn priority: user-blocking, which sets no QoS clamp on the host
    /// (``MayBlockPriority/spawnClamp`` is nil), so the host's main thread runs at the user-interactive
    /// QoS it sets itself (browser_host_main.mm). `posix_spawnattr_set_qos_class_np`
    /// is only a clamp and refuses user-interactive, so the spawn names no class.
    static let priority: MayBlockPriority = .userBlocking

    /// Spawns hosts off the main thread, on the user-blocking launcher (Chrome's process launcher,
    /// content/browser/child_process_launcher_helper.cc): the host draws the page a person is looking at.
    private let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.chromium-host", priority: Self.priority)

    /// - Parameter exitQueue: The serial queue the exit events of this launcher's hosts arrive on.
    init(exitQueue: DispatchQueue = DispatchQueue(label: "com.cmuxterm.chromium-host.exit", qos: .userInitiated)) {
        self.exitQueue = exitQueue
    }

    func launch(executable: URL, arguments: [String]) async throws -> ChromiumHostProcessHandle {
        let priority = launcher.priority
        return try await launcher.run { () throws(LaunchError) -> ChromiumHostProcessHandle in
            try Self.spawn(executable: executable, arguments: arguments, priority: priority)
        }
    }

    /// ``launch(executable:arguments:)``'s work, on the launcher (a test calls it on its own thread to
    /// set the spawning thread's signal mask).
    static func spawn(executable: URL, arguments: [String],
                      priority: MayBlockPriority) throws(LaunchError) -> ChromiumHostProcessHandle {
        let toHost = try socketPair()
        let fromHost: [Int32]
        do throws(LaunchError) {
            fromHost = try socketPair()
        } catch {
            toHost.forEach { _ = Darwin.close($0) }
            throw error
        }
        do throws(LaunchError) {
            let pid = try spawn(executable: executable, arguments: arguments, hostEnds: [toHost[1], fromHost[1]], priority: priority)
            return ChromiumHostProcessHandle(pid: pid, readFD: fromHost[0], writeFD: toHost[0])
        } catch {
            Darwin.close(toHost[0])
            Darwin.close(fromHost[0])
            throw error
        }
    }

    /// The Chromium Host of host mode (``ChromiumHostSupervisor``): one stream `socketpair`, the host's end on its
    /// fd 3, where browser_host_main.mm reads its control channel (`kControlFd`), the rest as
    /// ``spawn(executable:arguments:priority:)`` starts a host. Returns the host's pid and cmux's end of the channel.
    static func spawnControlled(executable: URL, arguments: [String],
                                priority: MayBlockPriority) throws(LaunchError) -> (pid: pid_t, controlFD: Int32) {
        let control = try socketPair()
        do throws(LaunchError) {
            let pid = try spawn(executable: executable, arguments: arguments, hostEnds: [control[1]], priority: priority)
            return (pid, control[0])
        } catch {
            Darwin.close(control[0])
            throw error
        }
    }

    /// One stream `socketpair`, both ends close-on-exec; cmux keeps index 0, the host gets index 1.
    private static func socketPair() throws(LaunchError) -> [Int32] {
        var pair: [Int32] = [-1, -1]
        // SAFETY: socketpair writes two descriptors into the two-element array during the call.
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw .socketPair(errno) }
        pair.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        // A write after the host died fails with EPIPE instead of a SIGPIPE.
        var noSigPipe: Int32 = 1
        // SAFETY: setsockopt reads the one Int32 `noSigPipe` holds, the length given, during the call.
        _ = unsafe setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return pair
    }

    /// Starts `executable` with `hostEnds` on its fds 3, 4, ... in order, and closes this process's copies of
    /// them whether or not it started.
    private static func spawn(executable: URL, arguments: [String], hostEnds: [Int32],
                              priority: MayBlockPriority) throws(LaunchError) -> pid_t {
        defer { hostEnds.forEach { _ = Darwin.close($0) } }
        // SAFETY (the spawn below): `actions` and `attributes` are initialized here and destroyed once by the
        // defers, after the spawn; each call reads or writes only them, the local signal sets and the
        // NUL-terminated strings Swift copies for the call.
        var actions: posix_spawn_file_actions_t?
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        unsafe posix_spawn_file_actions_addinherit_np(&actions, 1)
        unsafe posix_spawn_file_actions_addinherit_np(&actions, 2)
        for (index, end) in hostEnds.enumerated() {
            unsafe posix_spawn_file_actions_adddup2(&actions, end, Int32(3 + index))
        }
        var attributes: posix_spawnattr_t?
        unsafe posix_spawnattr_init(&attributes)
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        var emptyMask = sigset_t()
        unsafe sigemptyset(&emptyMask)
        var everySignal = sigset_t()
        unsafe sigfillset(&everySignal)
        unsafe posix_spawnattr_setsigmask(&attributes, &emptyMask)
        unsafe posix_spawnattr_setsigdefault(&attributes, &everySignal)
        unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        // SAFETY: strdup copies each argument, NUL-terminated, and the list ends with NULL; the copies are freed
        // once by the defer, after posix_spawn copied them into the child.
        let argv: [UnsafeMutablePointer<CChar>?] = unsafe ([executable.path] + arguments).map { unsafe strdup($0) } + [nil]
        defer { unsafe argv.forEach { unsafe free($0) } }
        var pid: pid_t = 0
        // SAFETY: as above; `environ` is the process's NULL-terminated environment, which posix_spawn copies.
        let result = unsafe blockingPosixSpawn(&pid, executable.path, &actions, &attributes, argv, environ, priority: priority)
        guard result == 0 else { throw .spawn(result) }
        return pid
    }

    func exit(of pid: pid_t) async -> ChromiumHostExit {
        if let ended = Self.exited(pid, blocking: false) { return ended }
        // A source dropped before its event (abandoned) is an exit with no status, as for a pid not ours.
        let exit = try? await withOnceContinuation { (continuation: OnceContinuation<ChromiumHostExit, OnceContinuationError>) in
            // DispatchSource process source: the carve-out for a child's exit (no Foundation async
            // API for a posix_spawn'ed pid); it never reaps, so the zombie stays until reap(_:).
            let queue = exitQueue
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
        return exit ?? ChromiumHostExit(signal: nil, status: nil)
    }

    /// The exit of `pid` without reaping it (`WNOWAIT`): nil while it runs
    /// (`blocking` false), or a status-less exit when it is not a child of
    /// this process (nothing to wait for).
    private static func exited(_ pid: pid_t, blocking: Bool) -> ChromiumHostExit? {
        var info = siginfo_t()
        let options = WEXITED | WNOWAIT | (blocking ? 0 : WNOHANG)
        // SAFETY: waitid writes one siginfo_t into `info` during the call.
        var result = unsafe waitid(P_PID, id_t(pid), &info, options)
        // SAFETY: as above.
        while result < 0 && errno == EINTR { result = unsafe waitid(P_PID, id_t(pid), &info, options) }
        guard result == 0 else { return ChromiumHostExit(signal: nil, status: nil) }  // not our child
        guard info.si_pid == pid else { return nil }  // WNOHANG: still running
        return info.si_code == CLD_EXITED
            ? ChromiumHostExit(signal: nil, status: info.si_status)
            : ChromiumHostExit(signal: info.si_status, status: nil)
    }

    func reap(_ pid: pid_t) {
        var status: Int32 = 0
        // SAFETY: waitpid writes one Int32 into `status` during the call.
        var result = unsafe waitpid(pid, &status, WNOHANG)
        // SAFETY: as above.
        while result < 0 && errno == EINTR { result = unsafe waitpid(pid, &status, WNOHANG) }
    }

    func kill(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }
}
#endif
