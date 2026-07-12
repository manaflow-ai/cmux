import Darwin
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
    private let clock = ContinuousClock()
    private let forceKillDelay = Duration.milliseconds(500)
    private let process: Process
    private var activeProcessIdentifier: pid_t?
    private var forceKillTask: Task<Void, Never>?
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
        let processIdentifier = process.processIdentifier
        if !hasExited { activeProcessIdentifier = processIdentifier }
        let shouldTerminate = isCancelled && !hasExited
        condition.unlock()
        if shouldTerminate { requestTermination(processIdentifier) }
    }

    func didExit() {
        condition.lock()
        hasExited = true
        activeProcessIdentifier = nil
        let task = forceKillTask
        forceKillTask = nil
        condition.unlock()
        task?.cancel()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        let processIdentifier = activeProcessIdentifier
        condition.unlock()
        if let processIdentifier { requestTermination(processIdentifier) }
    }

    private func requestTermination(_ processIdentifier: pid_t) {
        _ = Darwin.kill(processIdentifier, SIGTERM)
        condition.lock()
        if activeProcessIdentifier == processIdentifier, forceKillTask == nil {
            let clock = clock
            let delay = forceKillDelay
            forceKillTask = Task.detached { [weak self] in
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                self?.forceKillIfActive(processIdentifier)
            }
        }
        condition.unlock()
    }

    private func forceKillIfActive(_ processIdentifier: pid_t) {
        condition.lock()
        let shouldKill = activeProcessIdentifier == processIdentifier
        condition.unlock()
        if shouldKill { _ = Darwin.kill(processIdentifier, SIGKILL) }
    }
}
