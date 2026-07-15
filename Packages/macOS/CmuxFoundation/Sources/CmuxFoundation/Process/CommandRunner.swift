public import Foundation
import Darwin
import os

/// Runs external commands with `Process`, capturing output and honoring an
/// optional deadline.
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
public struct CommandRunner: OutputLimitedCommandRunning, Sendable {
    /// The default fallback `PATH` directories searched when a command is not on `PATH`.
    public static let defaultFallbackSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    // Hosts the one-shot deadline timers. A queue is used only for timer
    // event delivery, never to serialize mutable state.
    private static let timerQueue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.timer")

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    let commandPathResolver: CommandPathResolver
    private let standardInputWriterFactory: @Sendable (FileHandle, Data) -> CommandStandardInputWriter?
    private let processGroupResolver: @Sendable (Process) -> pid_t?

    /// Creates a command runner.
    /// - Parameters:
    ///   - environment: The environment whose `PATH` is searched; defaults to the process environment.
    ///   - bundledBinPath: An extra directory searched ahead of the fallbacks (the app's
    ///     bundled CLI directory); defaults to `Bundle.main`'s `Contents/Resources/bin`.
    ///   - fallbackSearchDirectories: Directories searched after `PATH` and the bundled bin.
    ///   - fileManager: Filesystem seam used to verify executable candidates.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories,
        fileManager: FileManager = .default
    ) {
        self.init(
            environment: environment,
            bundledBinPath: bundledBinPath,
            fallbackSearchDirectories: fallbackSearchDirectories,
            fileManager: fileManager,
            standardInputWriterFactory: CommandStandardInputWriter.init
        )
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories,
        fileManager: FileManager = .default,
        standardInputWriterFactory: @escaping @Sendable (FileHandle, Data) -> CommandStandardInputWriter?,
        processGroupResolver: @escaping @Sendable (Process) -> pid_t? = { process in
            let processGroupID = getpgid(process.processIdentifier)
            if processGroupID > 1,
               processGroupID == process.processIdentifier,
               processGroupID != getpgrp() {
                return processGroupID
            }
            return nil
        }
    ) {
        commandPathResolver = CommandPathResolver(
            environment: environment,
            bundledBinPath: bundledBinPath,
            fallbackSearchDirectories: fallbackSearchDirectories,
            fileManager: fileManager
        )
        self.standardInputWriterFactory = standardInputWriterFactory
        self.processGroupResolver = processGroupResolver
    }

    /// Runs `executable` with optional stdin data and an optional per-stream output limit.
    ///
    /// - Parameters:
    ///   - directory: The working directory for the process.
    ///   - executable: A command name or absolute path.
    ///   - arguments: The arguments passed to the command.
    ///   - standardInput: Bytes written to stdin before closing the pipe, or `nil`
    ///     to leave stdin disconnected.
    ///   - maximumOutputBytes: The greatest number of bytes retained from each stream,
    ///     or `nil` to capture without a byte limit.
    ///   - timeout: A deadline in seconds, or `nil` to wait indefinitely.
    /// - Returns: The ``CommandResult`` describing how the command finished.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data?,
        maximumOutputBytes: Int?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        await runCommand(
            directory: directory,
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            maximumOutputBytes: maximumOutputBytes,
            timeout: timeout
        )
    }

    private func runCommand(
        directory: String,
        executable: String,
        arguments: [String],
        standardInput: Data?,
        maximumOutputBytes: Int?,
        timeout: TimeInterval?
    ) async -> CommandResult {
        let cancelledResult = CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            cancellationCleanupSucceeded: true,
            executionError: "Command cancelled."
        )
        let cancellationCleanupFailedResult = CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            cancellationCleanupSucceeded: false,
            executionError: "Command cancelled, but its process tree did not exit."
        )
        guard !Task.isCancelled else { return cancelledResult }

        let process = Process()
        let cancellation = CommandCancellationRegistration()
        let stdinPipe = standardInput.map { _ in Pipe() }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if let resolved = resolvedCommandPath(executable: executable) {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            // The two stdout/stderr readers, the termination handler, the deadline timer,
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
                let (completed, timerToCancel, writerToCancel): (
                    CommandResult?,
                    (any DispatchSourceTimer)?,
                    CommandStandardInputWriter?
                ) =
                    state.withLock { s in
                        mutate(&s)
                        let writer = s.didTerminate ? s.standardInputWriter : nil
                        if writer != nil {
                            s.standardInputWriter = nil
                        }
                        guard !s.resumed, let out = s.stdout, let err = s.stderr, s.didTerminate else {
                            return (nil, nil, writer)
                        }
                        s.resumed = true
                        let timer = s.deadlineTimer
                        s.deadlineTimer = nil
                        return (
                            CommandResult(
                                stdout: String(data: out, encoding: .utf8),
                                stderr: String(data: err, encoding: .utf8),
                                exitStatus: s.exitStatus,
                                timedOut: false,
                                executionError: nil
                            ),
                            timer,
                            writer
                        )
                    }
                timerToCancel?.cancel()
                writerToCancel?.cancel()
                if let completed {
                    cancellation.finish()
                    continuation.resume(returning: completed)
                }
            }

            // Resume immediately with a terminal result (timeout or spawn failure),
            // independent of the pipe readers. Returns whether this call won the race.
            @Sendable func claimImmediate(_ result: CommandResult) -> Bool {
                let (won, timerToCancel, writerToCancel, readersToCancel): (
                    Bool,
                    (any DispatchSourceTimer)?,
                    CommandStandardInputWriter?,
                    [CommandOutputReader]
                ) =
                    state.withLock { s in
                        if s.resumed { return (false, nil, nil, []) }
                        s.resumed = true
                        let timer = s.deadlineTimer
                        s.deadlineTimer = nil
                        let writer = s.standardInputWriter
                        s.standardInputWriter = nil
                        let readers = [s.standardOutputReader, s.standardErrorReader].compactMap { $0 }
                        s.standardOutputReader = nil
                        s.standardErrorReader = nil
                        return (true, timer, writer, readers)
                    }
                timerToCancel?.cancel()
                writerToCancel?.cancel()
                readersToCancel.forEach { $0.cancel() }
                if won {
                    cancellation.finish()
                    continuation.resume(returning: result)
                }
                return won
            }

            @Sendable func beginCancellation() {
                let (shouldCancel, processGroupID, timer, writer, readers): (
                    Bool,
                    pid_t?,
                    (any DispatchSourceTimer)?,
                    CommandStandardInputWriter?,
                    [CommandOutputReader]
                ) = state.withLock { state in
                    guard !state.resumed, !state.cancellationRequested else {
                        return (false, state.processGroupID, nil, nil, [])
                    }
                    state.cancellationRequested = true
                    let timer = state.deadlineTimer
                    state.deadlineTimer = nil
                    let writer = state.standardInputWriter
                    state.standardInputWriter = nil
                    let readers = [state.standardOutputReader, state.standardErrorReader].compactMap { $0 }
                    state.standardOutputReader = nil
                    state.standardErrorReader = nil
                    return (true, state.processGroupID, timer, writer, readers)
                }
                guard shouldCancel else { return }
                timer?.cancel()
                writer?.cancel()
                readers.forEach { $0.cancel() }

                CommandProcessTreeTerminator.terminate(
                    process,
                    processGroupID: processGroupID,
                    completion: { processTreeExited in
                        _ = claimImmediate(
                            processTreeExited ? cancelledResult : cancellationCleanupFailedResult
                        )
                    }
                )
            }

            @Sendable func terminateAfterClaim(_ result: CommandResult) {
                if claimImmediate(result) {
                    let processGroupID = state.withLock { $0.processGroupID }
                    CommandProcessTreeTerminator.terminate(process, processGroupID: processGroupID)
                }
            }

            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                let (readers, wasCancelled) = state.withLock {
                    (
                        [$0.standardOutputReader, $0.standardErrorReader].compactMap { $0 },
                        $0.cancellationRequested
                    )
                }
                readers.forEach { $0.processDidExit() }
                if wasCancelled {
                    state.withLock {
                        $0.didTerminate = true
                        $0.exitStatus = status
                    }
                } else {
                    recordAndCompleteIfReady {
                        $0.didTerminate = true
                        $0.exitStatus = status
                    }
                }
            }

            do {
                try process.run()
                if let childProcessGroup = processGroupResolver(process) {
                    state.withLock { $0.processGroupID = childProcessGroup }
                }
            } catch {
                let message = String(describing: error)
                try? stdinPipe?.fileHandleForReading.close()
                try? stdinPipe?.fileHandleForWriting.close()
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = claimImmediate(CommandResult(
                    stdout: nil, stderr: nil, exitStatus: nil, timedOut: false, executionError: message
                ))
                return
            }

            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            guard let outputReader = CommandOutputReader(
                fileHandle: stdoutPipe.fileHandleForReading,
                maximumBytes: maximumOutputBytes,
                completion: { capture in
                    if capture.limitExceeded {
                        terminateAfterClaim(CommandResult(
                            stdout: String(data: capture.data, encoding: .utf8),
                            stderr: nil,
                            exitStatus: nil,
                            timedOut: false,
                            outputLimitExceeded: true,
                            executionError: nil
                        ))
                    } else {
                        recordAndCompleteIfReady {
                            $0.stdout = capture.data
                            $0.standardOutputReader = nil
                        }
                    }
                }
            ) else {
                terminateAfterClaim(CommandResult(
                    stdout: nil,
                    stderr: nil,
                    exitStatus: nil,
                    timedOut: false,
                    executionError: "Could not create the process stdout reader."
                ))
                return
            }
            guard let errorReader = CommandOutputReader(
                fileHandle: stderrPipe.fileHandleForReading,
                maximumBytes: maximumOutputBytes,
                completion: { capture in
                    if capture.limitExceeded {
                        terminateAfterClaim(CommandResult(
                            stdout: nil,
                            stderr: String(data: capture.data, encoding: .utf8),
                            exitStatus: nil,
                            timedOut: false,
                            outputLimitExceeded: true,
                            executionError: nil
                        ))
                    } else {
                        recordAndCompleteIfReady {
                            $0.stderr = capture.data
                            $0.standardErrorReader = nil
                        }
                    }
                }
            ) else {
                outputReader.start()
                outputReader.cancel()
                terminateAfterClaim(CommandResult(
                    stdout: nil,
                    stderr: nil,
                    exitStatus: nil,
                    timedOut: false,
                    executionError: "Could not create the process stderr reader."
                ))
                return
            }
            let readerStartup = state.withLock { s -> (cancel: Bool, processExited: Bool) in
                guard !s.resumed else { return (true, s.didTerminate) }
                s.standardOutputReader = outputReader
                s.standardErrorReader = errorReader
                return (false, s.didTerminate)
            }
            outputReader.start()
            errorReader.start()
            if readerStartup.cancel {
                outputReader.cancel()
                errorReader.cancel()
            } else if readerStartup.processExited {
                outputReader.processDidExit()
                errorReader.processDidExit()
            }

            if let stdinPipe, let standardInput {
                try? stdinPipe.fileHandleForReading.close()
                guard let writer = standardInputWriterFactory(
                    stdinPipe.fileHandleForWriting,
                    standardInput
                ) else {
                    try? stdinPipe.fileHandleForWriting.close()
                    terminateAfterClaim(CommandResult(
                        stdout: nil,
                        stderr: nil,
                        exitStatus: nil,
                        timedOut: false,
                        executionError: "Could not create the process stdin writer."
                    ))
                    return
                }
                let cancelImmediately = state.withLock { s -> Bool in
                    guard !s.didTerminate, !s.resumed else { return true }
                    s.standardInputWriter = writer
                    return false
                }
                if cancelImmediately {
                    writer.cancel()
                }
            }

            // Arm the deadline only after a successful launch, so the timeout handler can
            // never call `terminate()` on an unlaunched Process (which raises). The deadline
            // bounds the WHOLE capture: it is cancelled only when the continuation resumes
            // (see the two `claim`/`record` helpers), never on process exit, so a descendant
            // that exits the immediate child but keeps a pipe open cannot strand `run`
            // without a deadline. A real deadline needs a timer and the async-native timers
            // are disallowed here (Task.sleep / DispatchQueue.asyncAfter); it is hidden
            // behind this runner.
            if let timeout {
                let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    let timedOut = CommandResult(
                        stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil
                    )
                    if claimImmediate(timedOut) {
                        let processGroupID = state.withLock { $0.processGroupID }
                        CommandProcessTreeTerminator.terminate(process, processGroupID: processGroupID)
                    }
                    timer.cancel()
                }
                // If the command already resumed before we armed the timer, drop it.
                let alreadyResumed = state.withLock { s -> Bool in
                    if s.resumed { return true }
                    s.deadlineTimer = timer
                    return false
                }
                if alreadyResumed {
                    timer.cancel()
                } else {
                    timer.resume()
                }
            }
            cancellation.install {
                beginCancellation()
            }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Mutable state shared across the stdout/stderr readers, termination handler, deadline
    /// timer, and spawn-failure path while one `run` resolves; guarded by a lock.
    private struct RunState {
        var stdout: Data?
        var stderr: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var processGroupID: pid_t?
        var resumed = false
        var cancellationRequested = false
        // The command deadline timer, cancelled when the continuation resumes (any path).
        var deadlineTimer: (any DispatchSourceTimer)?
        var standardInputWriter: CommandStandardInputWriter?
        var standardOutputReader: CommandOutputReader?
        var standardErrorReader: CommandOutputReader?
    }

}
