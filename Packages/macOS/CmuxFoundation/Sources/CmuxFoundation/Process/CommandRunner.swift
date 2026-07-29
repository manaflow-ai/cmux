public import Foundation
import Darwin
import os

/// Sendable ownership boundary for Dispatch's thread-safe timer source.
private final class CommandTimer: @unchecked Sendable {
    private let source: any DispatchSourceTimer

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    func schedule(deadline: DispatchTime) {
        source.schedule(deadline: deadline)
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func cancel() {
        source.cancel()
    }

    func resume() {
        source.resume()
    }
}

/// Sendable ownership boundary for a nonblocking child-exit dispatch source.
private final class CommandProcessExitSource: @unchecked Sendable {
    private let source: any DispatchSourceProcess

    init(processIdentifier: pid_t, queue: DispatchQueue) {
        source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func cancel() {
        source.cancel()
    }

    func resume() {
        source.resume()
    }
}

/// Serializes cancellation with suspended process-group launch.
final class CommandCancellationLatch: @unchecked Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var isFinished = false
        var notification: (@Sendable () -> Void)?
        var action: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Installs the result-side cancellation notification before launch.
    /// Cancellation that arrived first invokes it immediately.
    func notifyOnCancel(_ notification: @escaping @Sendable () -> Void) {
        let notifyNow = state.withLock { state -> Bool in
            guard !state.isFinished else { return false }
            if state.isCancelled { return true }
            state.notification = notification
            return false
        }
        if notifyNow {
            notification()
        }
    }

    /// Launches the child suspended without holding the cancellation lock, then
    /// atomically installs the matching group-termination action. Cancellation
    /// that arrives during launch wins registration and terminates the child
    /// before it can be resumed.
    func launch(
        _ operation: @Sendable () throws -> pid_t,
        onCancel: @escaping @Sendable (pid_t) -> Void
    ) rethrows -> pid_t? {
        let mayLaunch = state.withLock { state in
            !state.isFinished && !state.isCancelled
        }
        guard mayLaunch else { return nil }

        let processIdentifier: pid_t
        do {
            processIdentifier = try operation()
        } catch {
            let wasCancelled = state.withLock { state in
                state.isFinished || state.isCancelled
            }
            if wasCancelled { return nil }
            throw error
        }

        let cancelLaunchedProcess = state.withLock { state -> Bool in
            guard !state.isFinished, !state.isCancelled else { return true }
            state.action = {
                onCancel(processIdentifier)
            }
            return false
        }
        guard !cancelLaunchedProcess else {
            onCancel(processIdentifier)
            return nil
        }
        return processIdentifier
    }

    /// Resumes a suspended launch while holding the same lock used by
    /// cancellation. `nil` means cancellation already owns the process.
    func resume(_ processIdentifier: pid_t) -> Int32? {
        state.withLock { state in
            guard !state.isFinished, !state.isCancelled else { return nil }
            guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
                return errno
            }
            return 0
        }
    }

    func cancel() {
        let actions = state.withLock { state -> (
            (@Sendable () -> Void)?,
            (@Sendable () -> Void)?
        ) in
            guard !state.isFinished else { return (nil, nil) }
            state.isCancelled = true
            let notification = state.notification
            state.notification = nil
            let action = state.action
            state.action = nil
            return (notification, action)
        }
        actions.0?()
        actions.1?()
    }

    func clear() {
        state.withLock { state in
            state.isFinished = true
            state.notification = nil
            state.action = nil
        }
    }
}

/// Runs external commands in dedicated POSIX process groups, capturing output
/// and honoring an optional deadline.
///
/// This is the production ``CommandRunning``. It resolves bare command names
/// against `PATH`, a bundled `bin` directory, and a set of fallback directories
/// (all injectable for tests), reads `stdout`/`stderr` concurrently so a full
/// pipe buffer cannot deadlock the child, and enforces the timeout with a
/// one-shot timer that terminates (then `SIGKILL`s) the process.
///
/// ```swift
/// let runner = CommandRunner()
/// let token = await runner.runStandardOutput(
///     directory: ".", executable: "gh", arguments: ["auth", "token"], timeout: 5
/// )
/// ```
public struct CommandRunner: CommandRunning, Sendable {
    /// The default fallback `PATH` directories searched when a command is not on `PATH`.
    public static let defaultFallbackSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// Seconds to wait after `SIGTERM` (on timeout) before sending `SIGKILL`.
    private static let sigkillGraceSeconds: Double = 0.2

    // Hosts the one-shot deadline/SIGKILL timers. A queue is used only for timer
    // event delivery, never to serialize mutable state.
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.timer")
    private static let processEventQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxProcess.exit"
    )
    // POSIX spawn is synchronous and can enter filesystem lookups. Move it off
    // the caller so cancellation and the command deadline remain observable.
    private static let spawnQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxProcess.spawn",
        qos: .utility,
        attributes: .concurrent
    )

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]
    private let standardErrorCaptureLimit: Int?

    /// Creates a command runner.
    /// - Parameters:
    ///   - environment: The environment whose `PATH` is searched; defaults to the process environment.
    ///   - bundledBinPath: An extra directory searched ahead of the fallbacks (the app's
    ///     bundled CLI directory); defaults to `Bundle.main`'s `Contents/Resources/bin`.
    ///   - fallbackSearchDirectories: Directories searched after `PATH` and the bundled bin.
    ///   - standardErrorCaptureLimit: Maximum stderr bytes retained while the full
    ///     stream is drained. `nil` retains all stderr; `0` discards it.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories,
        standardErrorCaptureLimit: Int? = nil
    ) {
        self.environment = environment
        self.bundledBinPath = bundledBinPath
        self.fallbackSearchDirectories = fallbackSearchDirectories
        self.standardErrorCaptureLimit = standardErrorCaptureLimit.map { max(0, $0) }
    }

    /// Runs `executable` with `arguments` in `directory`, capturing its output.
    ///
    /// Implements ``CommandRunning/run(directory:executable:arguments:timeout:)``:
    /// resolves `executable` against the configured `PATH`/bundled-bin/fallbacks,
    /// drains `stdout`/`stderr` concurrently, and enforces `timeout` with a one-shot
    /// timer that terminates (then `SIGKILL`s) the process. See the protocol for the
    /// full contract.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name (resolved against `PATH`) or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - timeout: A deadline in seconds; when it elapses the process is terminated
    ///     and the result has ``CommandResult/timedOut`` set. `nil` waits indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let commandPath: String
        let commandArguments: [String]
        if let resolved = resolvedCommandPath(executable: executable) {
            commandPath = resolved
            commandArguments = arguments
        } else {
            commandPath = "/usr/bin/env"
            commandArguments = [executable] + arguments
        }

        let stdoutReadHandle = stdoutPipe.fileHandleForReading
        let stderrReadHandle = stderrPipe.fileHandleForReading
        let stdoutWriteHandle = stdoutPipe.fileHandleForWriting
        let stderrWriteHandle = stderrPipe.fileHandleForWriting
        let outFD = Darwin.dup(stdoutReadHandle.fileDescriptor)
        let errFD = Darwin.dup(stderrReadHandle.fileDescriptor)
        guard outFD >= 0, errFD >= 0 else {
            let errorCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            if outFD >= 0 { _ = Darwin.close(outFD) }
            if errFD >= 0 { _ = Darwin.close(errFD) }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: POSIXError(errorCode).localizedDescription
            )
        }
        let stderrCaptureLimit = standardErrorCaptureLimit
        let cancellation = CommandCancellationLatch()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                // The two stdout/stderr readers, the process exit observer, the deadline timer,
                // and the spawn-failure path race to resume this continuation exactly once.
                // They run on synchronous, non-async callbacks, so a lock guards the small
                // shared state (the captured streams, the termination flag, the resumed latch)
                // and each callback resumes inline. An `actor` here would only force every
                // callback through `Task`/`await` to guard a few fields. (Per CLAUDE.md's lock
                // carve-out for synchronous coordination from non-async callbacks.)
                let state = OSAllocatedUnfairLock(initialState: RunState())

                // A stream finished or the process exited: record it, and resume with the
                // captured output only once stdout, stderr, AND termination have all arrived.
                // The timeout path never goes through here, so a descendant that inherited a
                // pipe and holds it open past the deadline can never delay the timeout result.
                @Sendable func recordAndCompleteIfReady(_ mutate: @Sendable (inout RunState) -> Void) {
                    let (completion, timerToCancel, exitSourceToCancel, reapProcess): (
                        (stdout: Data, stderr: Data, exitStatus: Int32?)?,
                        CommandTimer?,
                        CommandProcessExitSource?,
                        (@Sendable () -> Void)?
                    ) =
                        state.withLock { s in
                            mutate(&s)
                            guard !s.resumed, let out = s.stdout, let err = s.stderr, s.didTerminate else {
                                return (nil, nil, nil, nil)
                            }
                            s.resumed = true
                            let timer = s.deadlineTimer
                            s.deadlineTimer = nil
                            let exitSource = s.processExitSource
                            s.processExitSource = nil
                            let reapProcess = s.processReapAction
                            s.processReapAction = nil
                            return (
                                (stdout: out, stderr: err, exitStatus: s.exitStatus),
                                timer,
                                exitSource,
                                reapProcess
                            )
                        }
                    timerToCancel?.cancel()
                    exitSourceToCancel?.cancel()
                    if let completion {
                        reapProcess?()
                        let completed = CommandResult(
                            stdout: String(data: completion.stdout, encoding: .utf8),
                            stderr: String(data: completion.stderr, encoding: .utf8),
                            exitStatus: completion.exitStatus,
                            timedOut: false,
                            executionError: nil
                        )
                        cancellation.clear()
                        continuation.resume(returning: completed)
                    }
                }

                // Resume immediately with a terminal result (timeout or spawn failure),
                // independent of the pipe readers. Returns whether this call won the race.
                @Sendable func claimImmediate(_ result: CommandResult) -> Bool {
                    let (won, timerToCancel, exitSourceToCancel): (
                        Bool,
                        CommandTimer?,
                        CommandProcessExitSource?
                    ) =
                        state.withLock { s in
                            if s.resumed { return (false, nil, nil) }
                            s.resumed = true
                            let timer = s.deadlineTimer
                            s.deadlineTimer = nil
                            let exitSource = s.processExitSource
                            s.processExitSource = nil
                            s.processReapAction = nil
                            return (true, timer, exitSource)
                        }
                    timerToCancel?.cancel()
                    exitSourceToCancel?.cancel()
                    if won {
                        continuation.resume(returning: result)
                    }
                    return won
                }

                @Sendable func closeParentPipeHandles() {
                    try? stdoutReadHandle.close()
                    try? stderrReadHandle.close()
                    try? stdoutWriteHandle.close()
                    try? stderrWriteHandle.close()
                }

                @Sendable func closeDetachedReadDescriptors() {
                    _ = Darwin.close(outFD)
                    _ = Darwin.close(errFD)
                }

                @Sendable func startPipeReaders() {
                    // Readers start only after spawn returns, so a stalled spawn
                    // does not also strand two blocking read workers.
                    Task.detached {
                        defer { _ = Darwin.close(outFD) }
                        let data = Self.readToEnd(fileDescriptor: outFD, captureLimit: nil)
                        recordAndCompleteIfReady { $0.stdout = data }
                    }
                    Task.detached {
                        defer { _ = Darwin.close(errFD) }
                        let data = Self.readToEnd(
                            fileDescriptor: errFD,
                            captureLimit: stderrCaptureLimit
                        )
                        recordAndCompleteIfReady { $0.stderr = data }
                    }
                }

                let cancelledResult = CommandResult(
                    stdout: nil,
                    stderr: nil,
                    exitStatus: nil,
                    timedOut: false,
                    executionError: nil,
                    cancelled: true
                )

                cancellation.notifyOnCancel {
                    _ = claimImmediate(cancelledResult)
                }

                // Arm the whole-command deadline before dispatching POSIX spawn.
                // If spawn stalls in filesystem resolution, the continuation
                // still completes and the latch terminates any PID registered later.
                if let timeout {
                    let timer = CommandTimer(queue: Self.timerQueue)
                    timer.schedule(deadline: .now() + max(0, timeout))
                    timer.setEventHandler {
                        let timedOut = CommandResult(
                            stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil
                        )
                        if claimImmediate(timedOut) {
                            cancellation.cancel()
                        }
                        timer.cancel()
                    }
                    timer.resume()
                    let alreadyResumed = state.withLock { s -> Bool in
                        if s.resumed { return true }
                        s.deadlineTimer = timer
                        return false
                    }
                    if alreadyResumed {
                        timer.cancel()
                    }
                }

                let stdoutReadDescriptor = stdoutReadHandle.fileDescriptor
                let stderrReadDescriptor = stderrReadHandle.fileDescriptor
                let stdoutWriteDescriptor = stdoutWriteHandle.fileDescriptor
                let stderrWriteDescriptor = stderrWriteHandle.fileDescriptor

                Self.spawnQueue.async {
                    defer { closeParentPipeHandles() }

                    let processGroupID: pid_t
                    do {
                        guard let launchedProcessIdentifier = try cancellation.launch({
                            try Self.spawnCommand(
                                executablePath: commandPath,
                                arguments: commandArguments,
                                environment: environment,
                                directory: directory,
                                stdoutFileDescriptor: stdoutWriteDescriptor,
                                stderrFileDescriptor: stderrWriteDescriptor,
                                fileDescriptorsToClose: [
                                    stdoutReadDescriptor,
                                    stdoutWriteDescriptor,
                                    stderrReadDescriptor,
                                    stderrWriteDescriptor,
                                ]
                            )
                        }, onCancel: { processIdentifier in
                            Self.terminateOwnedProcessTree(
                                processGroupID: processIdentifier
                            )
                        }) else {
                            closeDetachedReadDescriptors()
                            _ = claimImmediate(cancelledResult)
                            return
                        }
                        processGroupID = launchedProcessIdentifier
                    } catch {
                        closeDetachedReadDescriptors()
                        let message = String(describing: error)
                        if claimImmediate(
                            CommandResult(
                                stdout: nil,
                                stderr: nil,
                                exitStatus: nil,
                                timedOut: false,
                                executionError: message
                            )
                        ) {
                            cancellation.clear()
                        }
                        return
                    }

                    startPipeReaders()

                    // Dispatch reports process exit without dedicating a worker
                    // for the child's lifetime. waitid is nonblocking here because
                    // the source fires only after exit, and WNOWAIT keeps the group
                    // leader owned until stream capture or escalation completes.
                    let exitSource = CommandProcessExitSource(
                        processIdentifier: processGroupID,
                        queue: Self.processEventQueue
                    )
                    exitSource.setEventHandler {
                        var exitInfo = siginfo_t()
                        var waitResult: Int32
                        repeat {
                            waitResult = Darwin.waitid(
                                P_PID,
                                id_t(processGroupID),
                                &exitInfo,
                                WEXITED | WNOWAIT | WNOHANG
                            )
                        } while waitResult == -1 && errno == EINTR

                        if waitResult == 0, exitInfo.si_pid == processGroupID {
                            let observedExitStatus = exitInfo.si_status
                            recordAndCompleteIfReady {
                                $0.didTerminate = true
                                $0.exitStatus = observedExitStatus
                            }
                        } else if waitResult == -1 {
                            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                            if claimImmediate(
                                CommandResult(
                                    stdout: nil,
                                    stderr: nil,
                                    exitStatus: nil,
                                    timedOut: false,
                                    executionError: POSIXError(code).localizedDescription
                                )
                            ) {
                                cancellation.cancel()
                            }
                        }
                    }
                    exitSource.resume()

                    let alreadyResumed = state.withLock { s -> Bool in
                        if s.resumed { return true }
                        s.processExitSource = exitSource
                        s.processReapAction = {
                            Self.reapProcess(processIdentifier: processGroupID)
                        }
                        return false
                    }
                    if alreadyResumed {
                        exitSource.cancel()
                    }

                    guard let resumeStatus = cancellation.resume(processGroupID) else {
                        return
                    }
                    guard resumeStatus == 0 else {
                        let code = POSIXErrorCode(rawValue: resumeStatus) ?? .EIO
                        _ = claimImmediate(
                            CommandResult(
                                stdout: nil,
                                stderr: nil,
                                exitStatus: nil,
                                timedOut: false,
                                executionError: POSIXError(code).localizedDescription
                            )
                        )
                        cancellation.cancel()
                        return
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Mutable state shared across the stdout/stderr readers, process exit observer, deadline
    /// timer, and spawn-failure path while one `run` resolves; guarded by a lock.
    private struct RunState: Sendable {
        var stdout: Data?
        var stderr: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var resumed = false
        // The command deadline timer, cancelled when the continuation resumes (any path).
        var deadlineTimer: CommandTimer?
        // Exit notification is event-driven; it never occupies a worker while
        // the child is running.
        var processExitSource: CommandProcessExitSource?
        // Normal completion reaps only after exit and both captured streams arrive.
        // Timeout/cancellation clears this and transfers reaping to SIGKILL escalation.
        var processReapAction: (@Sendable () -> Void)?
    }

    private static func terminateOwnedProcessTree(
        processGroupID: pid_t
    ) {
        if Darwin.killpg(processGroupID, SIGTERM) != 0, errno != ESRCH {
            _ = Darwin.kill(processGroupID, SIGTERM)
        }
        scheduleSigkill(processGroupID: processGroupID)
    }

    private static func scheduleSigkill(
        processGroupID: pid_t
    ) {
        let timer = CommandTimer(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            _ = Darwin.killpg(processGroupID, SIGKILL)
            DispatchQueue.global(qos: .utility).async {
                reapProcess(processIdentifier: processGroupID)
            }
            timer.cancel()
        }
        timer.resume()
    }

    private static func reapProcess(processIdentifier: pid_t) {
        var rawStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processIdentifier, &rawStatus, 0)
        } while waitResult == -1 && errno == EINTR
    }

    private static func spawnCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        stdoutFileDescriptor: Int32,
        stderrFileDescriptor: Int32,
        fileDescriptorsToClose: [Int32]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try "/dev/null".withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            )
        }
        try directory.withCString { path in
            try throwIfPOSIXError(
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            )
        }
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdoutFileDescriptor,
                STDOUT_FILENO
            )
        )
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stderrFileDescriptor,
                STDERR_FILENO
            )
        )
        for descriptor in Set(fileDescriptorsToClose) where descriptor > STDERR_FILENO {
            try throwIfPOSIXError(
                posix_spawn_file_actions_addclose(&fileActions, descriptor)
            )
        }

        var attributes: posix_spawnattr_t?
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
        )
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))
        try throwIfPOSIXError(posix_spawnattr_setflags(&attributes, flags))

        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processIdentifier: pid_t = 0
        let spawnStatus = try withMutableCStringArray(argumentStrings) { argumentPointers in
            try withMutableCStringArray(environmentStrings) { environmentPointers in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try throwIfPOSIXError(spawnStatus)
        guard processIdentifier > 1 else { throw POSIXError(.ECHILD) }
        return processIdentifier
    }

    private static func throwIfPOSIXError(_ status: Int32) throws {
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw POSIXError(.EINVAL)
        }
        var pointers = try strings.map { string -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            return pointer
        }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw POSIXError(.EINVAL)
            }
            return try body(baseAddress)
        }
    }

    private static func readToEnd(
        fileDescriptor: Int32,
        captureLimit: Int?
    ) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                let bytesToCapture = captureLimit.map {
                    min(bytesRead, max(0, $0 - data.count))
                } ?? bytesRead
                if bytesToCapture > 0 {
                    data.append(contentsOf: buffer[0..<bytesToCapture])
                }
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }

    /// Resolves `executable` to an absolute path, searching `PATH`, the bundled
    /// bin directory, and the fallback directories. Returns `nil` when nothing
    /// executable is found (the caller then runs it via `/usr/bin/env`).
    ///
    /// Internal rather than private so the resolution policy can be unit-tested
    /// directly with an injected environment and fallback directories.
    func resolvedCommandPath(executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        appendSearchPath(bundledBinPath)
        fallbackSearchDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
