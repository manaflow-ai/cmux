import Foundation

/// Transfers one synchronous scheduler result across the serial execution boundary.
///
/// Safety: `state` is accessed only while holding `stateLock`. The semaphore bridges a
/// synchronous socket worker onto the ordered delivery lane, and every wait is bounded.
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

    func resolve(with operation: () -> Value) {
        stateLock.lock()
        guard case .pending = state else {
            stateLock.unlock()
            return
        }
        state = .running
        stateLock.unlock()

        let value = operation()

        stateLock.lock()
        guard case .running = state else {
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
