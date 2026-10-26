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
    private let primitive: UnsafeMutablePointer<os_unfair_lock> // concurrency-allow: the one os_unfair_lock in Packages (p10-stability-172), held only for the caller's short critical section
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
        // Default attributes: a normal mutex; init with them cannot fail on glibc or musl.
        _ = pthread_mutex_init(primitive, nil)
        #endif
    }

    deinit {
        #if !canImport(os)
        pthread_mutex_destroy(primitive)
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
        _ = pthread_mutex_lock(primitive) // a normal mutex reports no error for a valid, initialized lock
        #endif
    }

    /// Takes the lock when it is free now; returns false when another thread holds it.
    @usableFromInline
    func tryLock() -> Bool {
        #if canImport(os)
        os_unfair_lock_trylock(primitive) // concurrency-allow: see `primitive`
        #else
        pthread_mutex_trylock(primitive) == 0
        #endif
    }

    /// Releases the lock this thread holds.
    @usableFromInline
    func unlock() {
        #if canImport(os)
        os_unfair_lock_unlock(primitive) // concurrency-allow: see `primitive`
        #else
        _ = pthread_mutex_unlock(primitive)
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
