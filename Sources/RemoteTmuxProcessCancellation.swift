import Foundation

/// Safety: the cancellation handler requires a `Sendable` capture, and this wrapper
/// stores immutable Foundation handles only to send idempotent terminate/close calls.
final class RemoteTmuxProcessCancellation: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func cancel() {
        if process.isRunning {
            process.terminate()
        }
        try? stdout.close()
        try? stderr.close()
    }
}
