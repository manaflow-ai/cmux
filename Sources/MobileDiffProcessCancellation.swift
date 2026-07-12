import Foundation

/// Cancellation token for one locally owned Git process.
///
/// `Process` is not declared `Sendable`, but Foundation permits `terminate()`
/// from another thread. This wrapper never exposes or replaces the process and
/// only forwards cancellation while the process is running.
final class MobileDiffProcessCancellation: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
