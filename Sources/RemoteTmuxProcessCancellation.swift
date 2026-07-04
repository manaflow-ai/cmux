import Foundation

/// Actor-owned process lifecycle coordinator for remote tmux command cancellation.
///
/// The cancellation handler can only schedule async work, so this actor owns the
/// mutable launch/cancel state and the non-`Sendable` Foundation handles. If
/// `cancel()` records cancellation before launch, `launch()` throws without
/// spawning a child. If launch wins, `cancel()` terminates the running child and
/// closes the pipe readers that the detached drain tasks are polling.
actor RemoteTmuxProcessCancellation {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var cancelled = false

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Launches the process unless cancellation already fired, then awaits exit.
    ///
    /// - Throws `CancellationError` if cancellation won the race. The child is not
    ///   started, so the `terminationHandler` will never fire.
    /// - Rethrows the underlying error if `process.run()` itself fails to launch.
    func launch() async throws -> Int32 {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
                if Task.isCancelled, process.isRunning {
                    process.terminate()
                }
            } catch {
                process.terminationHandler = nil
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: RemoteTmuxError.launchFailed(error.localizedDescription))
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        if process.isRunning {
            process.terminate()
        }
        try? stdout.close()
        try? stderr.close()
    }
}
