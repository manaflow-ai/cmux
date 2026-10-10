internal import os

/// A value that only one thread at a time can read or change, with the API of
/// `Synchronization.Mutex` (macOS 15) so that cmux-next runs on macOS 14
/// (plans/cmux-next/macos-floor.md). It uses the same lock as the system type
/// on Darwin, `os_unfair_lock`, so behavior is the same on every supported
/// macOS. Import this module instead of `Synchronization`; call sites do not
/// change.
public struct Mutex<Value: ~Copyable>: ~Copyable {
    private let storage: LockedStorage<Value>

    /// Makes a mutex that holds `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        storage = LockedStorage(initialValue)
    }

    /// Runs `body` with exclusive access to the value and returns its result.
    /// Do not call `withLock` on the same mutex from inside `body`: the lock
    /// is not recursive.
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        storage.lock()
        defer { storage.unlock() }
        return try body(&storage.pointer.pointee)
    }

    /// Runs `body` with exclusive access to the value when the lock is free
    /// now; returns nil without running `body` when another thread holds it.
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard storage.tryLock() else { return nil }
        defer { storage.unlock() }
        return try body(&storage.pointer.pointee)
    }
}

extension Mutex: @unchecked Sendable where Value: ~Copyable {} // crash-allow: the lock serializes every access, as in Synchronization.Mutex

/// The heap cells behind ``Mutex`` and ``Atomic``: one `os_unfair_lock` and
/// the value it protects. The lock needs a stable address, so it lives in its
/// own allocation, never inline in a struct.
final class LockedStorage<Value: ~Copyable>: @unchecked Sendable { // crash-allow: every access holds lockPointer
    let pointer: UnsafeMutablePointer<Value>
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>

    init(_ initialValue: consuming Value) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: initialValue)
        lockPointer = .allocate(capacity: 1)
        lockPointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
        lockPointer.deinitialize(count: 1)
        lockPointer.deallocate()
    }

    func lock() {
        os_unfair_lock_lock(lockPointer)
    }

    func tryLock() -> Bool {
        os_unfair_lock_trylock(lockPointer)
    }

    func unlock() {
        os_unfair_lock_unlock(lockPointer)
    }
}
