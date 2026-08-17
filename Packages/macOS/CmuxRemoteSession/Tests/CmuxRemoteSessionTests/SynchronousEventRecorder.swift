import Foundation

/// Counts synchronous test callbacks behind a short, nonblocking lock.
final class SynchronousEventRecorder: @unchecked Sendable {
    // lint:allow lock - event callbacks increment one test counter.
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock {
            value += 1
        }
    }
}
