import Foundation

// Protects test-clock state behind short synchronous critical sections because the gate reads time while actor-isolated.
final class ManualNanosecondClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}
