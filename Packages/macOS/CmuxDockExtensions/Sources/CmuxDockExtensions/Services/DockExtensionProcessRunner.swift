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

    /// Whether the process exited 0 without timing out.
    public var succeeded: Bool { exitStatus == 0 && !timedOut }

    /// Creates a result value.
    public init(exitStatus: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
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
        // Watchdog: fires SIGTERM at the deadline and SIGKILL after a short
        // grace, then reports whether it fired. Signals go by pid (Sendable)
        // so no non-Sendable Process crosses into the task; a signal to an
        // already-exited pid is a harmless ESRCH. Both sleeps are the
        // concurrency policy's bounded-delay carve-out (a subprocess
        // wall-clock timeout), not poll/settle races for app state, and both
        // exit early via cancellation the moment the process ends.
        let pid = process.processIdentifier
        let watchdog = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false // Process exited before the deadline.
            }
            kill(pid, SIGTERM)
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return true // SIGTERM was enough.
            }
            kill(pid, SIGKILL)
            return true
        }
        await waitTask.value
        watchdog.cancel()
        let timedOut = await watchdog.value

        try? stdoutHandle.close()
        try? stderrHandle.close()

        return DockExtensionProcessResult(
            exitStatus: process.terminationStatus,
            standardOutput: Self.readCapped(stdoutURL),
            standardError: Self.readCapped(stderrURL),
            timedOut: timedOut
        )
    }

    private static func readCapped(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let capped = data.count > outputByteLimit ? data.prefix(outputByteLimit) : data
        return String(decoding: capped, as: UTF8.self)
    }
}
