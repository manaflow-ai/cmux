public import Darwin
import Foundation

/// Locked cancellation state shared by synchronous `Process` callbacks.
/// `onCancel` cannot await an actor, so mutable state stays behind `lock`.
public final class RipgrepProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let sendSignal: @Sendable (pid_t, Int32) -> Int32
    private var activeProcessIdentifier: pid_t?
    private var finishedProcessIdentifier: pid_t?

    /// - Parameter sendSignal: how a signal is delivered to a pid. Defaults to
    ///   `Darwin.kill`; tests inject a recorder to observe SIGTERM delivery.
    public init(sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = Darwin.kill) {
        self.sendSignal = sendSignal
    }

    /// Records that the launched process has begun. If a finish was already
    /// observed for the same pid (a race where termination beat the start
    /// notification), the active pid stays cleared so `cancel()` is a no-op.
    public func markStarted(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        if finishedProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        } else {
            activeProcessIdentifier = processIdentifier
        }
    }

    /// Records that the process has exited; clears the active pid so a later
    /// `cancel()` cannot signal a recycled pid.
    public func markFinished(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        finishedProcessIdentifier = processIdentifier
        if activeProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        }
    }

    /// Signals SIGTERM to the active process, if any. Safe to call before the
    /// process starts or after it finishes (both are no-ops).
    public func cancel() {
        lock.lock()
        let processIdentifier = activeProcessIdentifier
        activeProcessIdentifier = nil
        lock.unlock()

        guard let processIdentifier else { return }
        _ = sendSignal(processIdentifier, SIGTERM)
    }
}
