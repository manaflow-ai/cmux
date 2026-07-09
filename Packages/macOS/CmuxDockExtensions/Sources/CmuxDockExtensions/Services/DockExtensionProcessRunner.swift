import Foundation

/// Outcome of one subprocess run.
public struct DockExtensionProcessResult: Equatable, Sendable {
    /// The process exit status (post-SIGKILL status when it timed out).
    public let exitStatus: Int32
    /// Captured standard output (truncated to the runner's cap).
    public let standardOutput: String
    /// Captured standard error (truncated to the runner's cap).
    public let standardError: String
    /// Whether the run hit its timeout and was terminated.
    public let timedOut: Bool
    /// Whether the run was terminated for exceeding the on-disk output cap.
    public let outputLimitExceeded: Bool

    /// Whether the process exited 0 without being terminated by the runner.
    public var succeeded: Bool { exitStatus == 0 && !timedOut && !outputLimitExceeded }

    /// Creates a result value.
    public init(
        exitStatus: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool,
        outputLimitExceeded: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.outputLimitExceeded = outputLimitExceeded
    }
}

/// Runs one subprocess to completion with a timeout, capturing stdout/stderr.
///
/// Output is redirected to temporary files rather than pipes, so a chatty
/// child (e.g. `npm install`) can never dead-lock on a full pipe buffer while
/// we wait for exit; the files are read back (capped) and deleted after the
/// run. Stateless and `Sendable`; ``DockExtensionGitService`` and
/// ``DockExtensionBuildRunner`` are the actor seams built on top.
public struct DockExtensionProcessRunner: Sendable {
    /// Cap applied to each captured stream when reading it back.
    public static let outputByteLimit = 1_048_576

    /// Creates a runner.
    public init() {}

    /// Runs `executableURL` with `arguments` and waits for exit.
    ///
    /// - Parameters:
    ///   - executableURL: The program to spawn.
    ///   - arguments: Its argv (excluding the program itself).
    ///   - currentDirectoryURL: Working directory, or inherit when `nil`.
    ///   - environment: Full child environment, or inherit when `nil`.
    ///   - timeout: Wall-clock limit; on expiry the child gets SIGTERM, then
    ///     SIGKILL after a 2s grace.
    /// - Returns: Exit status plus captured output.
    /// - Throws: ``DockExtensionError/gitUnavailable(detail:)``-shaped spawn
    ///   errors are the caller's to map; this throws the raw `Process.run()`
    ///   error when the program cannot be spawned.
    public func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> DockExtensionProcessResult {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-extension-run-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let (terminated, terminationContinuation) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in
            terminationContinuation.yield(())
            terminationContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw error
        }

        let waitTask = Task { for await _ in terminated {} }
        // Watchdog: a subprocess resource guard, not an app-state poll. Each
        // 500ms tick (the concurrency policy's bounded-delay carve-out,
        // cancelled the moment the process exits) enforces two limits — the
        // wall-clock deadline, and an on-disk cap on the temp output files so
        // a runaway child cannot fill the disk during its allotted time. On
        // breach: SIGTERM, 2s grace, SIGKILL, all by pid (Sendable); signaling
        // an already-exited pid is a harmless ESRCH.
        let pid = process.processIdentifier
        let watchdog = Task<(timedOut: Bool, outputLimitExceeded: Bool), Never> {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            func terminate() async {
                kill(pid, SIGTERM)
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return // SIGTERM was enough.
                }
                kill(pid, SIGKILL)
            }
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return (false, false) // Process exited before any breach.
                }
                if Self.onDiskSize(stdoutURL) + Self.onDiskSize(stderrURL) > Self.onDiskOutputLimit {
                    await terminate()
                    return (false, true)
                }
                if clock.now >= deadline {
                    await terminate()
                    return (true, false)
                }
            }
        }
        await waitTask.value
        watchdog.cancel()
        let verdict = await watchdog.value

        try? stdoutHandle.close()
        try? stderrHandle.close()

        return DockExtensionProcessResult(
            exitStatus: process.terminationStatus,
            standardOutput: Self.readCapped(stdoutURL),
            standardError: Self.readCapped(stderrURL),
            timedOut: verdict.timedOut,
            outputLimitExceeded: verdict.outputLimitExceeded
        )
    }

    /// Combined on-disk cap for a run's stdout+stderr temp files. Generous for
    /// real build logs, small enough that a runaway child cannot fill /tmp.
    public static let onDiskOutputLimit = 64 * 1_048_576

    private static func onDiskSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    private static func readCapped(_ url: URL) -> String {
        // Bounded read: a chatty child can write far more than the cap to the
        // temp file during its run; never allocate the whole file just to
        // truncate it afterwards.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: outputByteLimit) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
