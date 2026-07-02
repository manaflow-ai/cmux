import Foundation

/// Safety: the cancellation handler requires a `Sendable` capture, and this wrapper
/// stores immutable Foundation handles only to send idempotent terminate/close calls.
///
/// A lock serializes `launch()` against `cancel()` so a cancellation that races the
/// process launch cannot slip through the gap between "not yet running" and "running".
/// Whichever call wins the lock, the outcome still honors the caller's hard timeout:
/// either the child never starts (`launch()` throws `CancellationError`), or it has
/// already started and `cancel()` is guaranteed to observe it and terminate it.
final class RemoteTmuxProcessCancellation: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let lock = NSLock()
    private var cancelled = false
    private var launched = false

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Launches the process unless `cancel()` already fired.
    ///
    /// - Throws `CancellationError` if cancellation won the race. The child is not
    ///   started, so the caller must resume its continuation itself — the
    ///   `terminationHandler` will never fire for a process that never ran.
    /// - Rethrows the underlying error if `process.run()` itself fails to launch.
    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            throw CancellationError()
        }
        try process.run()
        launched = true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let didLaunch = launched
        lock.unlock()
        // `terminate()` raises if the process was never launched, so gate on our own
        // launch flag — not just `isRunning`, which reads false during the launch race
        // and is exactly what let a just-started child slip past cancellation before.
        if didLaunch, process.isRunning {
            process.terminate()
        }
        try? stdout.close()
        try? stderr.close()
    }
}
