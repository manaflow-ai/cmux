public import Foundation
public import Darwin

/// Locked cancellation state shared by synchronous `Process` callbacks while a
/// transcript-scan `rg` invocation is in flight.
///
/// `RipgrepFileScanner.matchingPaths` runs under `withTaskCancellationHandler`,
/// and the `onCancel` closure cannot await an actor, so the launched process's
/// identifier is tracked behind an `NSLock` and the cancellation signal is sent
/// synchronously. `sendSignal` is injected (defaulting to `Darwin.kill`) so the
/// signalling behavior is testable without spawning a real process.
public final class SessionIndexRipgrepCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let sendSignal: @Sendable (pid_t, Int32) -> Int32
    private var activeProcessIdentifier: pid_t?
    private var finishedProcessIdentifier: pid_t?

    /// Create a cancellation tracker.
    /// - Parameter sendSignal: Closure used to deliver a signal to a process id;
    ///   defaults to `Darwin.kill`. Injected for testability.
    public init(sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = Darwin.kill) {
        self.sendSignal = sendSignal
    }

    /// Record that the launched process has started.
    ///
    /// If the termination handler already reported the same pid as finished, the
    /// active pid is cleared so a late cancel cannot signal a recycled pid.
    public func markStarted(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        if finishedProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        } else {
            activeProcessIdentifier = processIdentifier
        }
    }

    /// Record that the launched process has finished, clearing the active pid if
    /// it matches.
    public func markFinished(processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        finishedProcessIdentifier = processIdentifier
        if activeProcessIdentifier == processIdentifier {
            activeProcessIdentifier = nil
        }
    }

    /// Signal the active process with `SIGTERM`, if one is still running.
    public func cancel() {
        lock.lock()
        let processIdentifier = activeProcessIdentifier
        activeProcessIdentifier = nil
        lock.unlock()

        guard let processIdentifier else { return }
        _ = sendSignal(processIdentifier, SIGTERM)
    }
}
