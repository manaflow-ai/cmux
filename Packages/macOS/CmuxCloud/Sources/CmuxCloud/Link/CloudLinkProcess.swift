import Darwin
import Foundation

/// One cmux-tui link client, spawned as the leader of its own process group.
///
/// `Foundation.Process` cannot set `POSIX_SPAWN_SETPGROUP`, and a parent-side
/// `setpgid` races a fast executable. Without a group, cancelling a link only
/// signals the client: a dial helper that ignores `SIGTERM` and inherited the
/// link's pipes survives and keeps the attempt wedged (#11008).
///
/// The leader is reaped as soon as it exits, like `Process`, and ``killGroup()``
/// later kills whatever is left of its group: at once on cancellation, or after
/// a bounded stderr drain when the client exits on its own. The kernel does not
/// hand out a PID that is still in use as a process group ID, so while any
/// member remains, the group ID stays ours.
///
/// An SSH link opts out of group signals (`sweepsGroup: false`). OpenSSH's
/// ProxyCommand child of a persisted `ControlMaster` stays in the group that
/// started it, and killing it would drop every connection sharing that master.
///
/// Unchecked Sendable: the identifiers and pipes are immutable, `exit`
/// synchronizes itself, and `lock` guards the two lifecycle flags.
final class CloudLinkProcess: @unchecked Sendable {
    let processIdentifier: Int32
    /// Whether ``signal(_:)`` and ``killGroup()`` reach the whole group, or
    /// only the leader.
    let sweepsGroup: Bool
    let standardOutput: Pipe
    let standardError: Pipe
    /// The leader's exit code, or its terminating signal number like
    /// `Process.terminationStatus`; -1 when the status could not be read.
    let exit = CloudLinkFirstValue<Int32>()

    private let lock = NSLock()
    private var exited = false
    private var groupKilled = false

    private init(processIdentifier: Int32, sweepsGroup: Bool, standardOutput: Pipe, standardError: Pipe) {
        self.processIdentifier = processIdentifier
        self.sweepsGroup = sweepsGroup
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Spawns `executableURL` with stdin on `/dev/null`, stdout and stderr on
    /// fresh pipes, default signal dispositions and no other inherited
    /// descriptors.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        sweepsGroup: Bool
    ) throws -> CloudLinkProcess {
        let standardOutput = Pipe()
        let standardError = Pipe()
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Pipe() can reuse a closed standard descriptor. Duplicate both write
        // ends above 2 so a dup2 into 1 or 2 never overwrites the other source.
        let outputWrite = fcntl(standardOutput.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        defer { if outputWrite >= 0 { Darwin.close(outputWrite) } }
        let errorWrite = fcntl(standardError.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        defer { if errorWrite >= 0 { Darwin.close(errorWrite) } }
        guard outputWrite >= 0, errorWrite >= 0 else { throw POSIXError(.EMFILE) }
        // POSIX_SPAWN_CLOEXEC_DEFAULT closes every descriptor that is not
        // named here, including the read ends.
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO) == 0
        else { throw POSIXError(.ENOMEM) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        var signalMask = sigset_t()
        sigfillset(&defaultSignals)
        sigemptyset(&signalMask)
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(flags)) == 0
        else { throw POSIXError(.EINVAL) }

        let path = executableURL.path
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let status = withCStringArray([path] + arguments) { argv in
            withCStringArray(environmentStrings) { envp in
                posix_spawn(&processIdentifier, path, &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else { throw spawnError(status, path: path) }
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
        let process = CloudLinkProcess(
            processIdentifier: processIdentifier,
            sweepsGroup: sweepsGroup,
            standardOutput: standardOutput,
            standardError: standardError
        )
        process.startReaper()
        return process
    }

    /// False once the leader has exited, even while its helpers still run.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !exited
    }

    /// Signals only the leader, so the client can shut its helpers down itself.
    func signalLeader(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return }
        _ = Darwin.kill(processIdentifier, signal)
    }

    /// Signals every process still in the link's group, or only a running
    /// leader when the link does not sweep its group.
    func signal(_ signal: Int32) {
        guard sweepsGroup else { return signalLeader(signal) }
        lock.lock()
        defer { lock.unlock() }
        guard !groupKilled else { return }
        _ = Darwin.kill(-processIdentifier, signal)
    }

    /// Kills whatever is left of the group, once. Returns when the group is
    /// gone, or after a one-second bound: SIGKILL is delivered asynchronously.
    func killGroup() async {
        guard sweepsGroup, markGroupKilled() else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        // Signal 0 is only a probe.
        while Darwin.kill(-processIdentifier, 0) == 0, ContinuousClock.now < deadline {
            try? await ContinuousClock().sleep(for: .milliseconds(5))
        }
    }

    private func markGroupKilled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !groupKilled else { return false }
        groupKilled = true
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        return true
    }

    private func startReaper() {
        let thread = Thread { [self] in
            var rawStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processIdentifier, &rawStatus, 0)
            } while result == -1 && errno == EINTR
            lock.lock()
            exited = true
            lock.unlock()
            exit.resolve(result == processIdentifier ? Self.terminationStatus(rawStatus) : -1)
        }
        thread.name = "cmux-cloud-link-reaper"
        thread.stackSize = 1 << 18
        thread.start()
    }

    /// Keeps the wording `Process.run()` used for a missing or unusable client.
    private static func spawnError(_ code: Int32, path: String) -> Error {
        switch code {
        case ENOENT: return CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        case EACCES, EPERM: return CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        default: return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The exit code, or the terminating signal number, as `Process` reports it.
    private static func terminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : signal
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
