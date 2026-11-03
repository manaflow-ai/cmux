internal import os

/// A value behind a lock, with `Synchronization.Mutex`'s `withLock` (which
/// needs macOS 15 / iOS 18; this package deploys to macOS 14 / iOS 17).
final class Mutex<Value>: @unchecked Sendable { // crash-allow: the lock serializes every access to `value`
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
