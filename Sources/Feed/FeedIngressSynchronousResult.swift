import Foundation

/// Transfers one synchronous scheduler result across the serial execution boundary.
///
/// Safety: the value is written once before signaling and read once after the semaphore wait.
final class FeedIngressSynchronousResult<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?

    func resolve(_ value: Value) {
        self.value = value
        semaphore.signal()
    }

    func wait() -> Value {
        semaphore.wait()
        return value!
    }
}
