#if canImport(os)
internal import os
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#else
#error("CmuxSafeConcurrency needs os_unfair_lock (Apple) or a pthread mutex (Glibc, Musl)")
#endif

/// The heap cell behind ``Mutex`` and ``PlatformLock``: the platform lock and the value it protects.
/// The lock needs a stable address, so it lives in its own allocation, never inline in a value that
/// can move.
@usableFromInline
final class MutexStorage<Value: ~Copyable>: @unchecked Sendable { // crash-allow: `value` is reached only between lock() and unlock(), and the platform lock's operations are thread-safe
    @usableFromInline let value: UnsafeMutablePointer<Value>
    #if canImport(os)
    private let primitive: UnsafeMutablePointer<os_unfair_lock> // concurrency-allow: the one os_unfair_lock in Packages, held only for the caller's short critical section
    #else
    private let primitive: UnsafeMutablePointer<pthread_mutex_t> // concurrency-allow: the portable lock's non-Apple primitive, held only for the caller's short critical section
    #endif

    @usableFromInline
    init(_ initialValue: consuming Value) {
        value = .allocate(capacity: 1)
        value.initialize(to: initialValue)
        primitive = .allocate(capacity: 1)
        #if canImport(os)
        primitive.initialize(to: os_unfair_lock()) // concurrency-allow: see `primitive`
        #else
        primitive.initialize(to: pthread_mutex_t())
        #if DEBUG
        // Chromium's base/synchronization/lock_impl_posix.cc: an error-checking mutex when DCHECKs are
        // on, so that misuse stops the process here as it does with os_unfair_lock on Apple.
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        pthread_mutexattr_settype(&attributes, Int32(PTHREAD_MUTEX_ERRORCHECK))
        let result = pthread_mutex_init(primitive, &attributes)
        pthread_mutexattr_destroy(&attributes)
        #else
        let result = pthread_mutex_init(primitive, nil)
        #endif
        assert(result == 0, "pthread_mutex_init failed with \(result)")
        #endif
    }

    deinit {
        #if !canImport(os)
        let result = pthread_mutex_destroy(primitive)
        assert(result == 0, "pthread_mutex_destroy failed with \(result) (EBUSY: the lock is still held)")
        #endif
        primitive.deinitialize(count: 1)
        primitive.deallocate()
        value.deinitialize(count: 1)
        value.deallocate()
    }

    /// Takes the lock, waiting while another thread holds it.
    @usableFromInline
    func lock() {
        #if canImport(os)
        os_unfair_lock_lock(primitive) // concurrency-allow: see `primitive`
        #else
        let result = pthread_mutex_lock(primitive)
        assert(result == 0, "pthread_mutex_lock failed with \(result) (EDEADLK: this thread already holds the lock)")
        #endif
    }

    /// Takes the lock when it is free now; returns false when another thread holds it.
    @usableFromInline
    func tryLock() -> Bool {
        #if canImport(os)
        os_unfair_lock_trylock(primitive) // concurrency-allow: see `primitive`
        #else
        let result = pthread_mutex_trylock(primitive)
        assert(result == 0 || result == EBUSY, "pthread_mutex_trylock failed with \(result)")
        return result == 0
        #endif
    }

    /// Releases the lock this thread holds.
    @usableFromInline
    func unlock() {
        #if canImport(os)
        os_unfair_lock_unlock(primitive) // concurrency-allow: see `primitive`
        #else
        let result = pthread_mutex_unlock(primitive)
        assert(result == 0, "pthread_mutex_unlock failed with \(result) (EPERM: this thread does not hold the lock)")
        #endif
    }

    /// Takes the lock another thread holds, with `observer` watching the wait; returns what to report
    /// after the unlock. Out of line: the uncontended path stays one try-lock.
    @usableFromInline @inline(never)
    func lockContended<Observer: MutexWaitObserver>(observedBy observer: Observer) -> Observer.Report? {
        guard let wait = observer.waitWillBegin() else {
            lock()
            return nil
        }
        lock()
        return observer.waitDidEnd(wait)
    }
}
