internal import Foundation

/// Tiny first-writer-wins result slot shared between the coordinator queue
/// and a semaphore-blocked caller (the synchronous PTY contract's completion
/// hand-off). The legacy code expressed this with a captured local `var`
/// guarded by the same `NSLock`; the box makes that confinement a type so it
/// crosses `@Sendable` boundaries under Swift 6. `@unchecked Sendable`
/// because every access is lock-guarded (the sanctioned tiny-value lock
/// shape, not a state machine).
final class LockedResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, any Error>?

    /// Stores `result` only when no result is set yet; returns whether this
    /// call stored it (the first-writer-wins latch).
    func setIfEmpty(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = result
        return true
    }

    /// Whether a result has been stored.
    var hasValue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    /// The stored result, if any.
    var current: Result<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
