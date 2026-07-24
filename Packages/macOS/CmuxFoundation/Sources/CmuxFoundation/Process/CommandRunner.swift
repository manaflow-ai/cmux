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

    // Environment is Apple-documented value-like once copied; stored as an immutable
    // dictionary so the struct stays Sendable.
    private let environment: [String: String]
    private let bundledBinPath: String?
    private let fallbackSearchDirectories: [String]

    /// Creates a command runner.
    /// - Parameters:
    ///   - environment: The environment whose `PATH` is searched; defaults to the process environment.
    ///   - bundledBinPath: An extra directory searched ahead of the fallbacks (the app's
    ///     bundled CLI directory); defaults to `Bundle.main`'s `Contents/Resources/bin`.
    ///   - fallbackSearchDirectories: Directories searched after `PATH` and the bundled bin.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinPath: String? = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        fallbackSearchDirectories: [String] = CommandRunner.defaultFallbackSearchDirectories
    ) {
        self.environment = environment
        self.bundledBinPath = bundledBinPath
        self.fallbackSearchDirectories = fallbackSearchDirectories
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
        let process = Process()
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor

        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
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
                let (completed, timerToCancel): (CommandResult?, CommandTimer?) =
                    state.withLock { s in
                        mutate(&s)
                        guard !s.resumed, let out = s.stdout, let err = s.stderr, s.didTerminate else {
                            return (nil, nil)
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
                            timer
                        )
                    }
                timerToCancel?.cancel()
                if let completed { continuation.resume(returning: completed) }
            }

            // Resume immediately with a terminal result (timeout or spawn failure),
            // independent of the pipe readers. Returns whether this call won the race.
            @Sendable func claimImmediate(_ result: CommandResult) -> Bool {
                let (won, timerToCancel): (Bool, CommandTimer?) =
                    state.withLock { s in
                        if s.resumed { return (false, nil) }
                        s.resumed = true
                        let timer = s.deadlineTimer
                        s.deadlineTimer = nil
                        return (true, timer)
                    }
                timerToCancel?.cancel()
                if won { continuation.resume(returning: result) }
                return won
            }

            // Drain both streams on detached tasks so a full pipe buffer cannot deadlock
            // the child. Fire-and-forget (never structurally awaited) so the timeout path
            // does not block on them. Keyed by the raw fd so no non-Sendable `FileHandle`
            // crosses the task boundary.
            Task.detached {
                let data = Self.readToEnd(fileDescriptor: outFD)
                recordAndCompleteIfReady { $0.stdout = data }
            }
            Task.detached {
                let data = Self.readToEnd(fileDescriptor: errFD)
                recordAndCompleteIfReady { $0.stderr = data }
            }

            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                recordAndCompleteIfReady {
                    $0.didTerminate = true
                    $0.exitStatus = status
                }
            }

            do {
                try process.run()
            } catch {
                let message = String(describing: error)
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = claimImmediate(CommandResult(
                    stdout: nil, stderr: nil, exitStatus: nil, timedOut: false, executionError: message
                ))
                return
            }

            // Close the parent's write ends so the readers see EOF once the child (and any
            // descendants that inherited them) close their copies.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            // Arm the deadline only after a successful launch, so the timeout handler can
            // never call `terminate()` on an unlaunched Process (which raises). The deadline
            // bounds the WHOLE capture: it is cancelled only when the continuation resumes
            // (see the two `claim`/`record` helpers), never on process exit, so a descendant
            // that exits the immediate child but keeps a pipe open cannot strand `run`
            // without a deadline. A real deadline needs a timer and the async-native timers
            // are disallowed here (Task.sleep / DispatchQueue.asyncAfter); it is hidden
            // behind this runner.
            if let timeout {
                let timer = CommandTimer(queue: Self.timerQueue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    let timedOut = CommandResult(
                        stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil
                    )
                    if claimImmediate(timedOut), process.isRunning {
                        process.terminate()
                        Self.scheduleSigkill(process)
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
        }
    }

    /// Mutable state shared across the stdout/stderr readers, termination handler, deadline
    /// timer, and spawn-failure path while one `run` resolves; guarded by a lock.
    private struct RunState: Sendable {
        var stdout: Data?
        var stderr: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var resumed = false
        // The command deadline timer, cancelled when the continuation resumes (any path).
        var deadlineTimer: CommandTimer?
    }

    private static func scheduleSigkill(_ process: Process) {
        let timer = CommandTimer(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            // Only SIGKILL if the Process is still running. If it already exited during
            // the grace window, sending to the bare pid could hit an unrelated process
            // that reused it; Foundation's `isRunning` confirms the pid is still ours.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }

    private static func readToEnd(fileDescriptor: Int32) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
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
