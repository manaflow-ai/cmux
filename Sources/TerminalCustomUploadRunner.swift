import CmuxFoundation
import CmuxRemoteSession
import CmuxSettings
import Darwin
import Foundation

/// Runs a user-configured custom upload command (see ``TerminalUploadCommand``)
/// in place of the built-in `scp`, once per dropped/pasted file, and produces the
/// single string cmux types into the terminal.
///
/// Isolated from the built-in transport on purpose: when no rule matches the
/// destination the terminal takes the normal `scp` path unchanged. Only when a
/// rule matches does the drop/paste route here instead.
///
/// Constructed at the call site with an injectable process runner — the default
/// spawns `/bin/sh` (see ``spawnCommand(command:environment:timeout:operation:)``),
/// and tests supply a fake, so there is no test seam in shipping source.
struct TerminalCustomUploadRunner {
    /// Executes `/bin/sh -c command` for one file and returns its exit status and
    /// captured output. Injected so tests can substitute a deterministic fake.
    typealias ProcessRunner = (
        _ command: String,
        _ environment: [String: String],
        _ timeout: TimeInterval,
        _ operation: TerminalImageTransferOperation
    ) throws -> (status: Int32, stdout: String, stderr: String)

    struct Endpoint: Sendable, Equatable {
        let destination: String
        let port: Int?
        let identityFile: String?
        let sshOptions: [String]
    }

    private let runProcess: ProcessRunner

    init(runProcess: @escaping ProcessRunner = TerminalCustomUploadRunner.spawnCommand) {
        self.runProcess = runProcess
    }

    /// The command matching `endpoint.destination`, or nil when the built-in
    /// transport should be used. Reads the `terminal.uploadCommands` rules from the
    /// settings catalog (cmux.json). Called on the main thread from the drop/paste
    /// sites, so the catalog is read via `MainActor.assumeIsolated`.
    private func matchedCommand(for endpoint: Endpoint) -> String? {
        let rules = MainActor.assumeIsolated {
            AppDelegate.shared?.settingsRuntime.map {
                $0.jsonStore.snapshotValue(for: $0.catalog.terminal.uploadCommands)
            } ?? []
        }
        return TerminalUploadCommand(rules: rules).command(forDestination: endpoint.destination)
    }

    /// Runs `command` once per file and returns the space-joined string to type
    /// (see ``TerminalUploadCommand/emittedText(commandStdout:remotePath:)`` for
    /// how each file's piece is derived). Fails (fail-closed) on any non-zero
    /// exit, timeout, or cancellation — cmux then types nothing, exactly like an
    /// `scp` failure today.
    func run(
        fileURLs: [URL],
        endpoint: Endpoint,
        command: String,
        operation: TerminalImageTransferOperation,
        timeout: TimeInterval = 120,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // The interior blocks on a POSIX process (spawn/waitpid/pipe reads), so it
        // runs off the main thread; the completion crosses back at the AppKit call
        // site. This is the callback boundary around a synchronous process bridge.
        DispatchQueue.global(qos: .userInitiated).async {
            completion(runSync(
                fileURLs: fileURLs,
                endpoint: endpoint,
                command: command,
                operation: operation,
                timeout: timeout
            ))
        }
    }

    func runSync(
        fileURLs: [URL],
        endpoint: Endpoint,
        command: String,
        operation: TerminalImageTransferOperation,
        timeout: TimeInterval = 120
    ) -> Result<String, Error> {
        guard !fileURLs.isEmpty else { return .success("") }
        var pieces: [String] = []
        do {
            for localURL in fileURLs {
                try operation.throwIfCancelled()
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw Self.uploadError("Dropped item is not a local file.")
                }
                let remotePath = RemoteSessionCoordinator.remoteDropPath(for: normalizedLocalURL)
                let env = TerminalUploadCommand.environment(
                    localPath: normalizedLocalURL.path,
                    remotePath: remotePath,
                    destination: endpoint.destination,
                    port: endpoint.port,
                    identityFile: endpoint.identityFile,
                    sshOptions: endpoint.sshOptions
                )
                let result = try runProcess(command, env, timeout, operation)
                guard result.status == 0 else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw Self.uploadError(
                        detail.isEmpty
                            ? "Upload command exited with status \(result.status)."
                            : "Upload command failed: \(detail)"
                    )
                }
                pieces.append(TerminalUploadCommand.emittedText(
                    commandStdout: result.stdout,
                    remotePath: remotePath
                ))
            }
            let joined = pieces.joined(separator: " ")
            guard !joined.isEmpty else {
                throw Self.uploadError("Upload command produced no output.")
            }
            return .success(joined)
        } catch {
            return .failure(error)
        }
    }

    /// If `plan` is a detected-ssh upload whose destination matches a configured
    /// rule, runs the custom command and delivers the outcome to `completion` on
    /// the main queue after the transfer operation is marked finished. Returns
    /// true when it took ownership — the caller must NOT run the built-in
    /// `execute`; false to fall through to the built-in transport unchanged.
    @discardableResult
    func handleIfMatched(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation,
        cleanup: @escaping ([URL]) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> Bool {
        guard case .uploadFiles(let fileURLs, .detectedSSH(let session)) = plan else {
            return false
        }
        let endpoint = Endpoint(
            destination: session.destination,
            port: session.port,
            identityFile: session.identityFile,
            sshOptions: session.sshOptions
        )
        guard let command = matchedCommand(for: endpoint) else { return false }

        run(fileURLs: fileURLs, endpoint: endpoint, command: command, operation: operation) { result in
            cleanup(fileURLs)
            DispatchQueue.main.async {
                // A cancelled/finished operation means the cancel handler already
                // completed the request; don't emit twice.
                guard operation.finish() else { return }
                completion(result)
            }
        }
        return true
    }

    // MARK: - Process bridge

    private static func uploadError(_ message: String) -> NSError {
        NSError(domain: "cmux.upload.command", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Default ``ProcessRunner``: spawns `/bin/sh -c command` as its own process
    /// group and captures its output.
    ///
    /// This is a synchronous POSIX process bridge, not ordinary async work: it
    /// spawns the child and blocks helper threads on `waitpid` and pipe reads,
    /// coordinating them with semaphores because an actor cannot own a blocking
    /// `waitpid`. It does two things the fixed-`scp` transport doesn't need, since
    /// the command is arbitrary user shell (a pipeline, `&&` chain, or wrapper):
    ///   * stdout and stderr are drained concurrently, before waiting on exit, so
    ///     a command that outruns a pipe buffer (verbose uploaders, `scp -v`)
    ///     can't deadlock against an unread pipe;
    ///   * it runs in a new process group (`POSIX_SPAWN_SETPGROUP`) and a
    ///     timeout/cancel signals the whole group, so the grandchild that actually
    ///     moves the file is killed — not just the `/bin/sh` parent.
    /// Byte caps on captured output — the emitted reference is small, so these
    /// bound memory (a runaway `yes`/verbose command can't OOM the app) while
    /// still draining past the cap so the writer never blocks.
    private static let maxStdoutBytes = 1 << 20   // 1 MiB
    private static let maxStderrBytes = 64 << 10  // 64 KiB (diagnostics only)

    static func spawnCommand(
        command: String,
        environment: [String: String],
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        try operation.throwIfCancelled()

        // Inherit the app environment (so PATH/HOME etc. resolve the user's tools)
        // and layer the CMUX_UPLOAD_* context on top.
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }

        var stdoutFDs: [Int32] = [-1, -1]
        var stderrFDs: [Int32] = [-1, -1]
        // Any fd still >= 0 at scope exit (including every throw) is closed here,
        // so no error path leaks a descriptor. Ownership transfers set entries to -1.
        defer { for fileDescriptor in stdoutFDs + stderrFDs where fileDescriptor >= 0 { close(fileDescriptor) } }

        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            throw uploadError("Failed to create upload command pipes.")
        }
        // Guard against a caller with closed stdio: a pipe fd equal to 0/1/2 would
        // collide with the dup2 targets below. Normal in-app fds are always >= 3.
        guard stdoutFDs.allSatisfy({ $0 > 2 }), stderrFDs.allSatisfy({ $0 > 2 }) else {
            throw uploadError("Upload command stdio is misconfigured.")
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw uploadError("Failed to prepare upload command.")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var setupOK = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDONLY, 0) == 0
        }
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO) == 0
        setupOK = setupOK && posix_spawn_file_actions_adddup2(&fileActions, stderrFDs[1], STDERR_FILENO) == 0
        for fileDescriptor in [stdoutFDs[0], stdoutFDs[1], stderrFDs[0], stderrFDs[1]] {
            setupOK = setupOK && posix_spawn_file_actions_addclose(&fileActions, fileDescriptor) == 0
        }
        guard setupOK else { throw uploadError("Failed to prepare upload command.") }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw uploadError("Failed to prepare upload command.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group led by the child (pgid == child pid) so the whole tree
        // can be signalled with kill(-pid, …). If this fails we must not spawn,
        // else timeout/cancel couldn't tear the group down.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw uploadError("Failed to prepare upload command.")
        }

        let argv = ["/bin/sh", "-c", command]
        let envp = mergedEnvironment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnStatus = withCStringArray(argv) { argvPtr in
            withCStringArray(envp) { envpPtr in
                "/bin/sh".withCString { path in
                    posix_spawn(&pid, path, &fileActions, &attributes, argvPtr, envpPtr)
                }
            }
        }

        // Parent keeps only the read ends; closing the write ends lets the reads
        // see EOF once every group member that inherited them exits.
        close(stdoutFDs[1]); stdoutFDs[1] = -1
        close(stderrFDs[1]); stderrFDs[1] = -1

        guard spawnStatus == 0 else {
            throw uploadError("Failed to launch upload command (error \(spawnStatus)).")
        }

        let spawned = SpawnedProcess(pid: pid)
        let stdoutReadFD = stdoutFDs[0]; stdoutFDs[0] = -1  // ownership moves to the drain
        let stderrReadFD = stderrFDs[0]; stderrFDs[0] = -1

        // Drain both pipes concurrently, before waiting on exit, with a byte cap.
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBuffer.set(drainPipe(stdoutReadFD, cap: maxStdoutBytes)); stdoutDrained.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBuffer.set(drainPipe(stderrReadFD, cap: maxStderrBytes)); stderrDrained.signal()
        }

        // `wakeup` is signalled by the reaper when the child exits AND by
        // cancellation, so the waits below block on a real event — never a timer or
        // a poll. On cancel/timeout the group gets SIGTERM, then SIGKILL after a
        // bounded grace if it hasn't died. Signalling only happens while the leader
        // is still alive (group non-empty), so the pgid can't have been reused.
        let wakeup = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            spawned.reap()
            wakeup.signal()
        }
        operation.installCancellationHandler {
            spawned.signalGroup(SIGTERM)
            wakeup.signal()
        }
        defer { operation.clearCancellationHandler() }

        // Blocks on `wakeup` until the child is reaped or `grace` elapses.
        func awaitExit(within grace: TimeInterval) -> Bool {
            let deadline = DispatchTime.now() + grace
            while !spawned.isReaped {
                if wakeup.wait(timeout: deadline) == .timedOut { break }
            }
            return spawned.isReaped
        }

        // First wait: exit, cancel, or the timeout budget — whichever comes first.
        let deadline = DispatchTime.now() + timeout
        while !spawned.isReaped && !operation.isCancelled {
            if wakeup.wait(timeout: deadline) == .timedOut { break }
        }

        var timedOut = false
        if !spawned.isReaped {
            timedOut = !operation.isCancelled
            spawned.signalGroup(SIGTERM)
            if !awaitExit(within: 1) {
                spawned.signalGroup(SIGKILL)
                _ = awaitExit(within: 5)
            }
        }

        // The leader exited, but a descendant — possibly `setsid`'d out of the
        // group, so a group kill can't reach it — could still hold a write end
        // open. Bound the drain, then close our read end to force the reader to
        // return. This can't hang and doesn't signal a possibly-reused pgid.
        finishDrain(stdoutDrained, closing: stdoutReadFD); stdoutFDs[0] = -1
        finishDrain(stderrDrained, closing: stderrReadFD); stderrFDs[0] = -1

        if operation.isCancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
        if timedOut {
            throw uploadError("Upload command timed out after \(Int(timeout))s.")
        }

        let stdoutResult = stdoutBuffer.get()
        guard !stdoutResult.truncated else {
            throw uploadError("Upload command produced too much output.")
        }
        // stdout is typed into the terminal, so fail closed on invalid UTF-8 rather
        // than inserting replacement characters. stderr is diagnostics only, so
        // decode it lossily.
        guard let stdout = String(data: stdoutResult.data, encoding: .utf8) else {
            throw uploadError("Upload command produced invalid (non-UTF-8) output.")
        }
        return (
            status: spawned.exitCode,
            stdout: stdout,
            stderr: String(decoding: stderrBuffer.get().data, as: UTF8.self)
        )
    }

    /// Waits up to 2s for `done`, then closes `fd` to force a still-blocked reader
    /// (a descendant holding the write end) to return — a bounded, hang-free drain.
    private static func finishDrain(_ done: DispatchSemaphore, closing fd: Int32) {
        if done.wait(timeout: .now() + 2) == .timedOut {
            close(fd)
            done.wait()
        } else {
            close(fd)
        }
    }

    /// Reads `fd` to EOF, keeping at most `cap` bytes but continuing to drain
    /// (discarding the overflow) so the writer never blocks on a full pipe. Returns
    /// the captured bytes and whether output was truncated.
    private static func drainPipe(_ fd: Int32, cap: Int) -> (data: Data, truncated: Bool) {
        var data = Data()
        var truncated = false
        let chunkSize = 1 << 16
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            if count > 0 {
                if data.count < cap {
                    let room = cap - data.count
                    if count <= room {
                        data.append(contentsOf: chunk.prefix(count))
                    } else {
                        data.append(contentsOf: chunk.prefix(room))
                        truncated = true
                    }
                } else {
                    truncated = true
                }
            } else if count == 0 {
                break  // EOF
            } else if errno != EINTR {
                break  // error or the fd was closed to unblock us
            }
        }
        return (data, truncated)
    }

    /// Builds a NULL-terminated C string array for `posix_spawn`, freeing the
    /// duplicated strings when `body` returns.
    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    /// Thread-safe accumulator for a drained pipe. A lock is used here (rather than
    /// an actor) because this is a low-level POSIX pipe bridge whose readers run on
    /// plain dispatch threads.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (data: Data, truncated: Bool) = (Data(), false)
        func set(_ newValue: (data: Data, truncated: Bool)) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> (data: Data, truncated: Bool) { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A spawned child process group, led by the `/bin/sh` child. A lock guards the
    /// wait status across the reaper thread and the caller; an actor can't own the
    /// blocking `waitpid` this wraps.
    private final class SpawnedProcess: @unchecked Sendable {
        private let lock = NSLock()
        private let groupID: pid_t
        private var rawStatus: Int32 = 0
        private var reaped = false

        init(pid: pid_t) { groupID = pid }

        /// Blocks until the group leader (`/bin/sh`) exits and records its status.
        func reap() {
            var status: Int32 = 0
            while true {
                let result = waitpid(groupID, &status, 0)
                if result == groupID { break }
                if result == -1 && errno == EINTR { continue }
                status = 0
                break
            }
            lock.lock()
            rawStatus = status
            reaped = true
            lock.unlock()
        }

        var isReaped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reaped
        }

        /// Signals the whole process group, unless the leader has been reaped — once
        /// reaped, the pgid may be empty and reusable, so signalling it could hit an
        /// unrelated group. The reap flag is checked and the signal sent under the
        /// same lock that `reap()` sets it with, so a signal never races past reap.
        /// We only ever signal the group, never a bare pid.
        func signalGroup(_ signal: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard !reaped else { return }
            _ = kill(-groupID, signal)
        }

        /// The command's exit code once reaped: the shell exit status, or
        /// `128 + signal` when the group was killed.
        var exitCode: Int32 {
            lock.lock()
            defer { lock.unlock() }
            if rawStatus & 0x7f == 0 { return (rawStatus >> 8) & 0xff }
            return 128 + (rawStatus & 0x7f)
        }
    }
}
