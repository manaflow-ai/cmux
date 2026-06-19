import Foundation

final class SSHPTYResizeCancellation: @unchecked Sendable {
    // @unchecked Sendable: `lock` protects the cancellation bit read from
    // signal/stdin callbacks, the actor event loop, and the blocking send worker.
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}
