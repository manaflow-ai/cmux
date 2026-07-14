public import Foundation

/// Runs `xcrun simctl` as a subprocess.
///
/// An `actor` so concurrent callers serialize their spawns through one place;
/// each ``run(_:)`` call is self-contained (fresh `Process`, fresh pipes) and
/// suspends without blocking any thread while the child runs.
public actor SimctlCommandRunner: SimctlCommandRunning {
    private let xcrunPath: String

    /// Creates a runner.
    ///
    /// - Parameter xcrunPath: The `xcrun` binary to spawn. Defaults to the
    ///   system `/usr/bin/xcrun`, which resolves `simctl` inside the selected
    ///   Xcode developer directory.
    public init(xcrunPath: String = "/usr/bin/xcrun") {
        self.xcrunPath = xcrunPath
    }

    /// Runs `xcrun simctl <arguments>` and returns its stdout.
    ///
    /// - Parameter arguments: The `simctl` subcommand and its arguments.
    /// - Returns: The process's stdout on exit status 0.
    /// - Throws: ``SimctlCommandFailure`` for a non-zero exit, or the
    ///   underlying spawn error when the process cannot launch.
    @discardableResult
    public func run(_ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = ["simctl"] + arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // One-shot exit signal: the termination handler is installed before
        // run() so it always fires, and yields into an AsyncStream the caller
        // awaits (a real signal, not a poll).
        var exitContinuation: AsyncStream<Void>.Continuation?
        let exitStream = AsyncStream<Void> { exitContinuation = $0 }
        let exitSignal = exitContinuation
        process.terminationHandler = { _ in
            exitSignal?.finish()
        }

        try process.run()

        let stdoutDescriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        async let stdoutData = Self.drain(fileDescriptor: stdoutDescriptor)
        async let stderrData = Self.drain(fileDescriptor: stderrDescriptor)
        for await _ in exitStream {}

        let output = await stdoutData
        let errorOutput = await stderrData
        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            throw SimctlCommandFailure(
                arguments: arguments,
                exitCode: exitCode,
                standardErrorText: String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        return output
    }

    /// Reads a pipe to EOF off-actor. Keyed by the raw descriptor because
    /// `FileHandle` is not `Sendable`; the detached task rebuilds a handle.
    private nonisolated static func drain(fileDescriptor: Int32) async -> Data {
        await Task.detached {
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            return (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
