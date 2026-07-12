import Foundation

/// Cancellation token for one locally owned Git process.
///
/// `Process` is not declared `Sendable`, but Foundation permits `terminate()`
/// from another thread. This wrapper never exposes or replaces the process and
/// only forwards cancellation while the process is running.
final class MobileDiffProcessCancellation: @unchecked Sendable {
    // Process launch/cancel are synchronous Foundation boundaries, so this
    // condition protects the cancellation latch without exposing mutable state.
    private let condition = NSCondition()
    private let process: Process
    private var isCancelled = false

    init(process: Process) {
        self.process = process
    }

    func beginLaunch() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !isCancelled
    }

    func didLaunch() {
        condition.lock()
        let shouldTerminate = isCancelled && process.isRunning
        condition.unlock()
        if shouldTerminate { process.terminate() }
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        let shouldTerminate = process.isRunning
        condition.unlock()
        if shouldTerminate { process.terminate() }
    }
}
