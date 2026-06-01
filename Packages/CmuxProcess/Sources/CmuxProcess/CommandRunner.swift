public import Foundation
import Darwin

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

        // Drain both streams concurrently on detached tasks so a full pipe buffer
        // cannot deadlock the child. Keyed by the raw fd so no non-Sendable
        // `FileHandle` crosses the task boundary.
        async let stdoutData: Data = Task.detached { Self.readToEnd(fileDescriptor: outFD) }.value
        async let stderrData: Data = Task.detached { Self.readToEnd(fileDescriptor: errFD) }.value

        let outcome = await waitForExit(
            process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeout: timeout
        )

        switch outcome {
        case .spawnFailed(let message):
            _ = await stdoutData
            _ = await stderrData
            return CommandResult(
                stdout: nil, stderr: nil, exitStatus: nil, timedOut: false, executionError: message
            )
        case .timedOut:
            // Drain the reads so the detached tasks finish (the handles hit EOF once
            // the terminated child's write ends close), but do not surface partial
            // output on a timeout.
            _ = await stdoutData
            _ = await stderrData
            return CommandResult(
                stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil
            )
        case .exited(let status):
            let out = await stdoutData
            let err = await stderrData
            return CommandResult(
                stdout: String(data: out, encoding: .utf8),
                stderr: String(data: err, encoding: .utf8),
                exitStatus: status,
                timedOut: false,
                executionError: nil
            )
        }
    }

    /// How a single `run` finished, bridged from `Process` callbacks into one value.
    private enum RunOutcome: Sendable {
        case exited(Int32)
        case timedOut
        case spawnFailed(String)
    }

    /// Ensures the continuation resumes exactly once across the termination,
    /// timeout, and spawn-failure callbacks, without a lock.
    private actor ResumeGuard {
        private var claimed = false
        /// Returns `true` only the first time it is called.
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private func waitForExit(
        _ process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval?
    ) async -> RunOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<RunOutcome, Never>) in
            let resumeGuard = ResumeGuard()

            var deadlineTimer: (any DispatchSourceTimer)?
            if let timeout {
                // A one-shot DispatchSource timer enforces the command deadline. Swift has
                // no async-native timer permitted in runtime code here (Task.sleep and
                // DispatchQueue.asyncAfter are disallowed), and a genuine subprocess deadline
                // is not a sleep-for-synchronization hack; the timer is hidden behind this
                // runner and never escapes.
                let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    Task {
                        if await resumeGuard.claim() {
                            process.terminate()
                            Self.scheduleSigkill(pid: process.processIdentifier)
                            continuation.resume(returning: .timedOut)
                        }
                    }
                    timer.cancel()
                }
                deadlineTimer = timer
                timer.resume()
            }

            // Capture the timer so it stays alive until the process exits, and cancel it
            // then so it cannot fire after a normal exit.
            process.terminationHandler = { [deadlineTimer] finished in
                deadlineTimer?.cancel()
                let status = finished.terminationStatus
                Task {
                    if await resumeGuard.claim() {
                        continuation.resume(returning: .exited(status))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                deadlineTimer?.cancel()
                let message = String(describing: error)
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                Task {
                    if await resumeGuard.claim() {
                        continuation.resume(returning: .spawnFailed(message))
                    }
                }
                return
            }

            // Close the parent's write ends so the reader handles see EOF once the
            // child exits.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }
    }

    private static func scheduleSigkill(pid: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            // `kill` on an already-reaped pid is harmless (ESRCH).
            kill(pid, SIGKILL)
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
