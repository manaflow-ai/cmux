import Foundation

/// Cancellation token for one locally owned Git process.
///
/// `Process` is not declared `Sendable`, but Foundation permits `terminate()`
/// from another thread. This wrapper never caches or signals a raw PID, which
/// could be reused after the child exits.
final class MobileDiffProcessCancellation: @unchecked Sendable {
    // Process launch/cancel are synchronous Foundation boundaries, so this
    // condition protects the cancellation latch without exposing mutable state.
    private let condition = NSCondition()
    private let process: Process
    private var hasExited = false
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
        let shouldTerminate = isCancelled && !hasExited && process.isRunning
        condition.unlock()
        if shouldTerminate { process.terminate() }
    }

    func didExit() {
        condition.lock()
        hasExited = true
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        let shouldTerminate = !hasExited && process.isRunning
        condition.unlock()
        if shouldTerminate { process.terminate() }
    }
}
