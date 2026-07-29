public import Foundation
import Darwin

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

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]
    private let standardErrorCaptureLimit: Int?
    private let processOperations: CommandProcessOperations

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
        self.processOperations = CommandProcessOperations()
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
                let coordinator = CommandRunCoordinator()

                @Sendable func finish(
                    _ completion: CommandRunCoordinator.Completion?
                ) async {
                    guard let completion else { return }
                    completion.timer?.cancel()
                    completion.exitSource?.cancel()
                    completion.reapProcess?()
                    await cancellation.clear()
                    continuation.resume(returning: completion.result)
                }

                @Sendable func claimImmediate(
                    _ result: CommandResult,
                    clearCancellation: Bool = false
                ) async -> Bool {
                    let claim = await coordinator.claimImmediate()
                    claim.timer?.cancel()
                    claim.exitSource?.cancel()
                    guard claim.won else { return false }
                    if clearCancellation {
                        await cancellation.clear()
                    }
                    continuation.resume(returning: result)
                    return true
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
                        let data = processOperations.readOutputToEnd(
                            fileDescriptor: outFD,
                            captureLimit: nil
                        )
                        await finish(await coordinator.recordStdout(data))
                    }
                    Task.detached {
                        defer { _ = Darwin.close(errFD) }
                        let data = processOperations.readOutputToEnd(
                            fileDescriptor: errFD,
                            captureLimit: stderrCaptureLimit
                        )
                        await finish(await coordinator.recordStderr(data))
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

                let stdoutReadDescriptor = stdoutReadHandle.fileDescriptor
                let stderrReadDescriptor = stderrReadHandle.fileDescriptor
                let stdoutWriteDescriptor = stdoutWriteHandle.fileDescriptor
                let stderrWriteDescriptor = stderrWriteHandle.fileDescriptor

                Task {
                    defer { closeParentPipeHandles() }

                    await cancellation.notifyOnCancel {
                        Task {
                            _ = await claimImmediate(cancelledResult)
                        }
                    }

                    // Arm the whole-command deadline before POSIX spawn. If
                    // spawn stalls in filesystem resolution, cancellation still
                    // completes the caller and owns any PID registered later.
                    if let timeout {
                        let timer = processOperations.makeDeadlineTimer()
                        timer.schedule(deadline: .now() + max(0, timeout))
                        timer.setEventHandler {
                            Task {
                                let timedOut = CommandResult(
                                    stdout: nil,
                                    stderr: nil,
                                    exitStatus: nil,
                                    timedOut: true,
                                    executionError: nil
                                )
                                if await claimImmediate(timedOut) {
                                    await cancellation.cancel()
                                }
                                timer.cancel()
                            }
                        }
                        if await coordinator.installDeadlineTimer(timer) {
                            timer.resume()
                        } else {
                            timer.cancel()
                        }
                    }

                    guard await cancellation.mayLaunch() else {
                        closeDetachedReadDescriptors()
                        _ = await claimImmediate(cancelledResult)
                        return
                    }

                    let processGroupID: pid_t
                    do {
                        processGroupID = try await processOperations.spawn(
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
                    } catch {
                        closeDetachedReadDescriptors()
                        if await cancellation.mayLaunch() {
                            _ = await claimImmediate(
                                CommandResult(
                                    stdout: nil,
                                    stderr: nil,
                                    exitStatus: nil,
                                    timedOut: false,
                                    executionError: String(describing: error)
                                ),
                                clearCancellation: true
                            )
                        } else {
                            _ = await claimImmediate(cancelledResult)
                        }
                        return
                    }

                    guard await cancellation.register(
                        processIdentifier: processGroupID,
                        onCancel: { processIdentifier in
                            processOperations.terminateOwnedProcessTree(
                                processGroupID: processIdentifier
                            )
                        }
                    ) else {
                        closeDetachedReadDescriptors()
                        _ = await claimImmediate(cancelledResult)
                        return
                    }

                    startPipeReaders()

                    // Dispatch reports process exit without dedicating a worker
                    // for the child's lifetime. waitid is nonblocking here because
                    // the source fires only after exit, and WNOWAIT keeps the group
                    // leader owned until stream capture or escalation completes.
                    let exitSource = processOperations.makeExitSource(
                        processIdentifier: processGroupID
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
                            Task {
                                await finish(
                                    await coordinator.recordExit(
                                        status: observedExitStatus
                                    )
                                )
                            }
                        } else if waitResult == -1 {
                            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                            Task {
                                if await claimImmediate(
                                    CommandResult(
                                        stdout: nil,
                                        stderr: nil,
                                        exitStatus: nil,
                                        timedOut: false,
                                        executionError: POSIXError(code).localizedDescription
                                    )
                                ) {
                                    await cancellation.cancel()
                                }
                            }
                        }
                    }

                    guard await coordinator.installExitSource(
                        exitSource,
                        reapProcess: {
                            processOperations.reap(
                                processIdentifier: processGroupID
                            )
                        }
                    ) else {
                        exitSource.cancel()
                        return
                    }
                    exitSource.resume()

                    guard let resumeStatus = await cancellation.resume(processGroupID) else {
                        return
                    }
                    guard resumeStatus == 0 else {
                        let code = POSIXErrorCode(rawValue: resumeStatus) ?? .EIO
                        _ = await claimImmediate(
                            CommandResult(
                                stdout: nil,
                                stderr: nil,
                                exitStatus: nil,
                                timedOut: false,
                                executionError: POSIXError(code).localizedDescription
                            )
                        )
                        await cancellation.cancel()
                        return
                    }
                }
            }
        } onCancel: {
            Task {
                await cancellation.cancel()
            }
        }
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
