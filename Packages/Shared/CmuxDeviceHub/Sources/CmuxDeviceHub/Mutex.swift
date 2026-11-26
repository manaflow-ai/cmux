#if canImport(os)
internal import os
#else
internal import Foundation
#endif

/// A value behind a lock, with `Synchronization.Mutex`'s `withLock` (which
/// needs macOS 15 / iOS 18; this package deploys to macOS 14 / iOS 17).
final class Mutex<Value>: @unchecked Sendable { // crash-allow: the lock serializes every access to `value`
    #if canImport(os)
    private let lock = OSAllocatedUnfairLock()
    #else
    // lint:allow lock - stands in for os.OSAllocatedUnfairLock where the os module is unavailable.
    private let lock = NSLock()
    #endif
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
