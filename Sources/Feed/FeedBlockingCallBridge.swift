import Foundation

/// Single-writer completion bridge for a synchronous control-socket worker.
///
/// The worker waits on the dispatch group up to its caller-provided safety
/// deadline while an async task owns Feed state. `DispatchGroup.leave()`
/// publishes the result before the waiting worker reads it, so no separate
/// mutable-state lock is needed.
final class FeedBlockingCallBridge<Value: Sendable>: @unchecked Sendable {
    private let completion = DispatchGroup()
    nonisolated(unsafe) private var value: Value?

    init() {
        completion.enter()
    }

    func finish(with value: Value) {
        self.value = value
        completion.leave()
    }

    func wait(timeout: TimeInterval) -> Value? {
        let boundedTimeout = timeout.isFinite ? max(timeout, 0) : 0
        guard completion.wait(timeout: .now() + boundedTimeout) == .success else {
            return nil
        }
        precondition(value != nil, "Feed blocking call completed without a result")
        return value
    }
}
