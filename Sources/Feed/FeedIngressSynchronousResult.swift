import Foundation

/// Transfers one synchronous scheduler result across the serial execution boundary.
///
/// Safety: `state` is accessed only while holding `stateLock`. The semaphore bridges a
/// synchronous socket worker onto the ordered delivery lane. A deadline may extend through
/// completion work after a committed mutation, so callers never observe an acknowledgment
/// before the delivery publishes its authoritative result.
final class FeedIngressSynchronousResult<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case running
        case committed(Value)
        case resolved(Value)
        case timedOut
    }

    private let stateLock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
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
    /// The operation must be a short, non-suspending mutation invoked only after
    /// all queue or actor hops. Holding the lock makes timeout and commit mutually
    /// exclusive. The ordered delivery lane resolves the caller only after the
    /// delivery closure returns, so publication after this mutation remains ordered
    /// before acknowledgment.
    func commit(_ operation: () -> Value) -> Value? {
        stateLock.lock()
        guard case .running = state else {
            stateLock.unlock()
            return nil
        }
        let value = operation()
        state = .committed(value)
        stateLock.unlock()
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

    func wait(timeout: TimeInterval) -> Value? {
        precondition(timeout > 0, "Synchronous Feed ingress requires a positive timeout")
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        stateLock.lock()
        if case .resolved(let value) = state {
            stateLock.unlock()
            return value
        }
        if case .committed = state {
            stateLock.unlock()
            // The authoritative mutation already happened before the deadline.
            // Completion publication must therefore finish before its caller can
            // observe that mutation as acknowledged.
            semaphore.wait()
            stateLock.lock()
            defer { stateLock.unlock() }
            guard case .resolved(let value) = state else { return nil }
            return value
        }
        if waitResult == .timedOut {
            state = .timedOut
        }
        stateLock.unlock()
        return nil
    }
}
