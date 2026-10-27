/// A lock with no value: the platform lock that ``Mutex`` is built on, for a type that keeps its own
/// state beside the lock (a portable stand-in for a system lock type). Prefer ``Mutex``, which ties the
/// state to the lock so that no access can skip it.
///
/// The layering is Chromium's: `base::Lock` over the platform `base::internal::LockImpl`
/// (base/synchronization/lock.h, lock_impl.h). On Apple platforms the lock is `os_unfair_lock`, the
/// lock `Synchronization.Mutex` and PartitionAlloc's `SpinningMutex` use there
/// (base/allocator/partition_allocator/src/partition_alloc/spinning_mutex.h): it donates the waiter's
/// priority to the owner. Elsewhere it is a pthread mutex, error-checking in Debug as Chromium's
/// lock_impl_posix.cc makes it when DCHECKs are on. It is not recursive: taking it again on the thread
/// that holds it stops the process (on Apple platforms always, elsewhere in Debug).
public struct PlatformLock: ~Copyable, Sendable {
    @usableFromInline let storage: MutexStorage<Void>

    /// Makes an unlocked lock.
    public init() {
        storage = MutexStorage(())
    }

    /// Runs `body` with the lock held and returns its result. Do not take the same lock again inside
    /// `body`: the lock is not recursive.
    @inlinable
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: () throws(E) -> Result
    ) throws(E) -> Result {
        storage.lock()
        defer { storage.unlock() }
        return try body()
    }

    /// Runs `body` with the lock held when the lock is free now; returns nil without running `body`
    /// when another thread holds it.
    @inlinable
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: () throws(E) -> Result
    ) throws(E) -> Result? {
        guard storage.tryLock() else { return nil }
        defer { storage.unlock() }
        return try body()
    }
}
