import Darwin
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
        let processIdentifier = process.processIdentifier
        if process.isRunning, processIdentifier > 1 {
            process.terminate()
            // Quit owns a hard deadline. OpenSSH normally exits on SIGTERM,
            // but a wedged executable or test double may ignore it.
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        try? stdout.close()
        try? stderr.close()
    }
}
