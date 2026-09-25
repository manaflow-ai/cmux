import Foundation

/// Transfers one synchronous scheduler result across the serial execution boundary.
///
/// Safety: `state` is accessed only while holding `stateLock`. The semaphore bridges a
/// synchronous socket worker onto the ordered delivery lane. If an authoritative mutation starts
/// before the deadline, the caller waits for its value even when publication finishes later;
/// this prevents an accepted item from being reported as unavailable.
final class FeedIngressSynchronousResult<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case running
        case committing
        case committed(Value)
        case resolved(Value)
        case timedOut
    }

    private let stateLock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let commitSemaphore = DispatchSemaphore(value: 0)
    private var state: State = .pending

    /// Claims execution after the ordered lane selects this delivery.
    func begin() -> Bool {
        stateLock.lock()
        guard case .pending = state else {
            stateLock.unlock()
            return false
        }
        state = .running
        stateLock.unlock()
        return true
    }

    /// Linearizes the bounded caller result with its synchronous mutation.
    ///
    /// The operation runs outside the state lock so a stalled queue or actor hop
    /// cannot block the timeout path before the mutation begins. The state changes
    /// to ``committing`` first; this reserves the operation's linearization point.
    func commit(_ operation: () -> Value) -> Value? {
        stateLock.lock()
        guard case .running = state else {
            stateLock.unlock()
            return nil
        }
        state = .committing
        stateLock.unlock()

        let value = operation()

        stateLock.lock()
        guard case .committing = state else {
            stateLock.unlock()
            return nil
        }
        state = .committed(value)
        stateLock.unlock()
        commitSemaphore.signal()
        return value
    }

    /// Resolves a committed value after all delivery-side publication completes.
    func complete() {
        stateLock.lock()
        guard case .committed(let value) = state else {
            stateLock.unlock()
            return
        }
        state = .resolved(value)
        stateLock.unlock()
        semaphore.signal()
    }

    /// Returns whether the delivery may still perform its authoritative
    /// mutation. The check is intentionally short so callers can place it
    /// immediately before an actor-backed insert after any queue hops.
    func isActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .committing = state { return true }
        return false
    }

    func wait(timeout: TimeInterval) -> Value? {
        precondition(timeout > 0, "Synchronous Feed ingress requires a positive timeout")
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        stateLock.lock()
        if case .resolved(let value) = state {
            stateLock.unlock()
            return value
        }
        if case .committed = state {
            defer { stateLock.unlock() }
            guard case .committed(let value) = state else { return nil }
            // The authoritative mutation happened within the deadline. Return it
            // even if its non-authoritative publication is still completing.
            return value
        }
        if case .committing = state {
            stateLock.unlock()
            // The authoritative mutation has started before the deadline.
            // Wait for its value so a late completion cannot be reported as
            // unavailable after the item was accepted.
            commitSemaphore.wait()
            stateLock.lock()
            defer { stateLock.unlock() }
            guard case .committed(let value) = state else { return nil }
            return value
        }
        if waitResult == .timedOut {
            state = .timedOut
        }
        stateLock.unlock()
        return nil
    }
}
