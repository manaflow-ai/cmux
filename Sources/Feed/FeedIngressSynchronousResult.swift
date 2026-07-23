import Foundation

/// Transfers one synchronous scheduler result across the serial execution boundary.
///
/// Safety: `state` is accessed only while holding `stateLock`. The semaphore bridges a
/// synchronous socket worker onto the ordered delivery lane. A deadline may extend only
/// through a short commit already executing under the lock, so callers never observe a
/// timeout after its mutation succeeds.
final class FeedIngressSynchronousResult<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case running
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
    /// exclusive: either timeout cancels first, or the caller receives this value.
    func commit(_ operation: () -> Value) -> Value? {
        stateLock.lock()
        guard case .running = state else {
            stateLock.unlock()
            return nil
        }
        let value = operation()
        state = .resolved(value)
        stateLock.unlock()
        semaphore.signal()
        return value
    }

    func wait(timeout: TimeInterval) -> Value? {
        precondition(timeout > 0, "Synchronous Feed ingress requires a positive timeout")
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        stateLock.lock()
        defer { stateLock.unlock() }
        if case .resolved(let value) = state {
            return value
        }
        if waitResult == .timedOut {
            state = .timedOut
        }
        return nil
    }
}
