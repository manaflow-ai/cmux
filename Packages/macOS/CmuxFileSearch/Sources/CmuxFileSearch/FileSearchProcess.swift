public import Darwin
public import Foundation

/// A command that prints `rg --json` output on stdout: ripgrep itself, or ssh
/// running ripgrep on another host.
public struct FileSearchCommand: Hashable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    /// Written to stdin and then closed. `nil` connects stdin to /dev/null.
    public var standardInput: Data?

    public init(executablePath: String, arguments: [String], standardInput: Data? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.standardInput = standardInput
    }
}

/// A running child process with streamed stdout.
///
/// Spawned with `posix_spawn` rather than `Process` for two reasons:
/// arguments reach the child byte for byte (Foundation converts them with
/// `fileSystemRepresentation`, which decomposes non-ASCII search text to NFD
/// and then misses NFC file contents), and the child leads its own process
/// group so cancellation also stops the processes ssh starts.
public final class FileSearchProcess: @unchecked Sendable {
    public enum SpawnError: Error, Equatable {
        case launchFailed(errno: Int32)
    }

    public let pid: pid_t
    private let stdoutRead: Int32
    private let stderrRead: Int32
    private let lock = NSLock()
    private var exited = false
    private var terminationRequested = false

    private static let ioQueue = DispatchQueue(
        label: "com.cmux.file-search.process-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Starts `command`. Throws when the executable cannot be launched.
    public init(command: FileSearchCommand) throws {
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        var stdinPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw SpawnError.launchFailed(errno: errno) }
        guard pipe(&stderrPipe) == 0 else {
            let code = errno
            Self.close(stdoutPipe)
            throw SpawnError.launchFailed(errno: code)
        }
        if command.standardInput != nil {
            guard pipe(&stdinPipe) == 0 else {
                let code = errno
                Self.close(stdoutPipe + stderrPipe)
                throw SpawnError.launchFailed(errno: code)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if command.standardInput != nil {
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three standard descriptors survive into the child, and the
        // child starts a new process group we can signal as a whole.
        // Ignored signal dispositions and the signal mask survive exec, so a
        // host that ignores SIGTERM or SIGPIPE would otherwise make the child
        // unkillable or change how ripgrep handles a closed pipe.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = [command.executablePath] + command.arguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for pointer in cArguments { free(pointer) } }

        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, command.executablePath, &fileActions, &attributes, &cArguments, environ)
        Self.close([stdoutPipe[1], stderrPipe[1]])
        if command.standardInput != nil { Self.close([stdinPipe[0]]) }
        guard status == 0 else {
            Self.close([stdoutPipe[0], stderrPipe[0]])
            if command.standardInput != nil { Self.close([stdinPipe[1]]) }
            throw SpawnError.launchFailed(errno: status)
        }
        pid = childPID
        stdoutRead = stdoutPipe[0]
        stderrRead = stderrPipe[0]

        if let input = command.standardInput {
            let writeEnd = stdinPipe[1]
            // A remote shell may exit before reading everything; never die of SIGPIPE.
            _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
            Self.ioQueue.async {
                input.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                        if written > 0 {
                            offset += written
                        } else if written < 0, errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                }
                Darwin.close(writeEnd)
            }
        }
    }

    /// Stdout chunks until end of file. The stream finishing does not mean
    /// the process exited; call ``waitForExit()`` for the status.
    public func standardOutputChunks(chunkSize: Int = 64 * 1024) -> AsyncStream<Data> {
        let descriptor = stdoutRead
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.terminate() }
            }
            Self.ioQueue.async {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        continuation.yield(Data(buffer[0..<count]))
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                Darwin.close(descriptor)
                continuation.finish()
            }
        }
    }

    /// Waits for exit and returns the status plus the last 8 KiB of stderr.
    public func waitForExit() async -> (status: Int32, standardError: String) {
        let descriptor = stderrRead
        let pid = self.pid
        return await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 8 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 {
                        collected.append(contentsOf: buffer[0..<count])
                        if collected.count > 8 * 1024 {
                            collected.removeFirst(collected.count - 8 * 1024)
                        }
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                Darwin.close(descriptor)
                // Observe the exit without reaping so the pid (and its group
                // id) cannot be reused before `terminate` learns it is gone.
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
                self.markExited()
                var rawStatus: Int32 = 0
                while waitpid(pid, &rawStatus, 0) < 0, errno == EINTR {}
                continuation.resume(returning: (
                    Self.exitCode(fromWaitStatus: rawStatus),
                    String(decoding: collected, as: UTF8.self)
                ))
            }
        }
    }

    /// Sends SIGTERM to the child's process group. Safe to call repeatedly
    /// and after exit; a reaped pid is never signalled.
    public func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !exited, !terminationRequested else { return }
        terminationRequested = true
        _ = Darwin.kill(-pid, SIGTERM)
    }

    private func markExited() {
        lock.lock()
        exited = true
        lock.unlock()
    }

    /// Shell-style exit code: the status, or 128 + signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 { return (status >> 8) & 0xFF }
        return 128 + signal
    }

    private static func close(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    }
}
