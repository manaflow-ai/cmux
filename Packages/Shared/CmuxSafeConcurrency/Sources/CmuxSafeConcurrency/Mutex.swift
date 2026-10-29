/// A value that only one thread at a time can read or change, with the API of `Synchronization.Mutex`
/// (macOS 15 / iOS 18) on the macOS 14 / iOS 17 floor. On Apple platforms it uses the same lock as the
/// system type, `os_unfair_lock` (``PlatformLock``), so it behaves the same on every supported OS; on
/// Linux a pthread mutex, error-checking in Debug. Chromium's equivalent is `base::Lock` with `GUARDED_BY` state
/// (base/synchronization/lock.h, base/thread_annotations.h); here the type system does the guarding: the
/// value is reachable only inside `withLock`.
public struct Mutex<Value: ~Copyable>: ~Copyable {
    @usableFromInline let storage: MutexStorage<Value>

    /// Makes a mutex that holds `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        storage = MutexStorage(initialValue)
    }

    /// Runs `body` with exclusive access to the value and returns its result. Do not call `withLock` on
    /// the same mutex from inside `body`: the lock is not recursive, and doing so stops the process
    /// (on Apple platforms always, elsewhere in Debug).
    @inlinable
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        storage.lock()
        defer { storage.unlock() }
        return try body(&storage.value.pointee)
    }

    /// ``withLock(_:)`` with `observer` watching a contended wait for the lock (``MutexWaitObserver``).
    /// When the lock is free this is one try-lock and `observer` is not called.
    @inlinable
    public borrowing func withLock<Observer: MutexWaitObserver, Result: ~Copyable, E: Error>(
        observedBy observer: Observer,
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        let report: Observer.Report? = storage.tryLock() ? nil : storage.lockContended(observedBy: observer)
        defer {
            storage.unlock()
            if let report { observer.lockReleased(report) }
        }
        return try body(&storage.value.pointee)
    }

    /// Runs `body` with exclusive access to the value when the lock is free now; returns nil without
    /// running `body` when another thread holds it.
    @inlinable
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard storage.tryLock() else { return nil }
        defer { storage.unlock() }
        return try body(&storage.value.pointee)
    }
}

/// Sendable as `Synchronization.Mutex` is: the value comes in `sending` and is reached only under the lock.
extension Mutex: Sendable where Value: ~Copyable {}
