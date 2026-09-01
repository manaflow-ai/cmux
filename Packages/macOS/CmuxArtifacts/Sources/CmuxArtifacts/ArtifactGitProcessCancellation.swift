import Darwin
import Foundation

/// Terminates a launched Git process from a synchronous cancellation callback.
// Safety: the Process reference is immutable. Launch and handler installation stay
// on the waiting task; concurrent cancellation only reads liveness and sends SIGKILL.
final class ArtifactGitProcessCancellation: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
