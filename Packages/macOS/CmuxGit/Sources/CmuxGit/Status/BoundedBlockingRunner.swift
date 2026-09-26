import Dispatch
import Foundation
import os

/// Runs one blocking job at a time on a dedicated serial queue, and waits for
/// it for at most a fixed time.
///
/// Filesystem probes on a hung network mount can block a thread indefinitely,
/// and a deadline checked between probes cannot interrupt one that is already
/// stuck. The runner bounds the *caller's* wait instead: whichever of the job
/// or the timeout finishes first resumes the caller, exactly once. A stuck job
/// keeps the runner busy until it returns, and further calls return `nil`
/// immediately rather than queueing behind it, so repeated attempts against a
/// hung mount cannot pile up blocked threads.
final class BoundedBlockingRunner: Sendable {
    private let queue: DispatchQueue
    private let isRunning = OSAllocatedUnfairLock(initialState: false)

    /// Creates a runner with its own serial queue.
    ///
    /// - Parameter label: The dispatch queue label, for diagnostics.
    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Runs `work` and returns its result, or `nil` when `timeout` elapses
    /// first or another job is still running.
    ///
    /// - Parameters:
    ///   - timeout: The longest the caller waits.
    ///   - work: The blocking job. It receives the deadline so it can stop
    ///     early between probes.
    /// - Returns: The job's result, or `nil` on timeout or when busy.
    func run<Value: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable (DispatchTime) -> Value?
    ) async -> Value? {
        let claimed = isRunning.withLock { running -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard claimed else { return nil }

        let deadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(timeout))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let resumeOnce = ResumeOnce(continuation)
            let isRunning = isRunning
            queue.async {
                let value = deadline > DispatchTime.now() ? work(deadline) : nil
                isRunning.withLock { $0 = false }
                resumeOnce.resume(returning: value)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                resumeOnce.resume(returning: nil)
            }
        }
    }

    private static func nanoseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let nanoseconds = Double(components.seconds) * 1_000_000_000
            + Double(components.attoseconds) / 1_000_000_000
        return Int(min(max(0, nanoseconds), Double(Int32.max) * 1_000))
    }
}

/// Resumes a continuation from whichever of several racing callers is first.
private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(returning value: Value) {
        let pending = continuation.withLock { stored -> CheckedContinuation<Value, Never>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }
}
