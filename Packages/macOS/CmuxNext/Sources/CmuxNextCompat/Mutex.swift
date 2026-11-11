internal import os
#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
#endif

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
    ///
    /// In Debug and bench builds (and cmux NEXT Nightly) a main-thread wait for the lock longer than
    /// ``BlockingKind/lockWaitLimitNanos`` is recorded by the main-thread blocking detector at the
    /// caller's `fileID`:`line` (never a trap: the wait includes scheduling time).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site; leave the default).
    ///   - line: The calling code's `#line`.
    ///   - body: The work done with the lock held.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        fileID: StaticString = #fileID, line: UInt = #line,
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        // A long main-thread wait is recorded after the unlock (Debug, bench and Nightly builds).
        let longWait = storage.lockNotingMainThreadWait()
        defer {
            storage.unlock()
            longWait?.mainThreadWaitedForLock(fileID: fileID, line: line)
        }
        #else
        storage.lock()
        defer { storage.unlock() }
        #endif
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

extension Mutex where Value: Copyable {
    /// Returns a copy of the value, read under the lock.
    ///
    /// Use this, not `withLock { $0 }`, to read a closure (or a tuple holding
    /// one). `withLock` hands its body the value `inout` at the generic
    /// abstraction; for a function type Swift converts the stored closure to the
    /// body's form and back, and writes the converted closure back, so every
    /// read wraps the stored handler in two more reabstraction thunks. A handler
    /// read once per main-thread stall grew 74,661 frames deep in 4.5 hours and
    /// overflowed the main thread's stack (#40144). `load()` copies the value out
    /// without `inout` and leaves the stored value as it was.
    ///
    /// ```swift
    /// private let sink = Mutex<(@Sendable (HangRecord) -> Void)?>(nil)
    /// sink.load()?(record)
    /// ```
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site in the blocking detector).
    ///   - line: The calling code's `#line`.
    /// - Returns: The value the mutex holds now.
    public borrowing func load(fileID: StaticString = #fileID, line: UInt = #line) -> Value {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let longWait = storage.lockNotingMainThreadWait()
        defer {
            storage.unlock()
            longWait?.mainThreadWaitedForLock(fileID: fileID, line: line)
        }
        #else
        storage.lock()
        defer { storage.unlock() }
        #endif
        return storage.pointer.pointee
    }

    /// Replaces the value under the lock, without the `inout` round trip of
    /// `withLock { $0 = newValue }` (``load()`` says why that matters for closures).
    ///
    /// - Parameters:
    ///   - newValue: The value the mutex holds from now on.
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    public borrowing func store(_ newValue: consuming sending Value, fileID: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let longWait = storage.lockNotingMainThreadWait()
        defer {
            storage.unlock()
            longWait?.mainThreadWaitedForLock(fileID: fileID, line: line)
        }
        #else
        storage.lock()
        defer { storage.unlock() }
        #endif
        storage.pointer.pointee = newValue
    }
}

extension Mutex: @unchecked Sendable where Value: ~Copyable {} // crash-allow: the lock serializes every access, as in Synchronization.Mutex

/// The heap cell behind ``Mutex``: one `os_unfair_lock` and
/// the value it protects. The lock needs a stable address, so it lives in its
/// own allocation, never inline in a struct.
final class LockedStorage<Value: ~Copyable>: @unchecked Sendable { // crash-allow: every access holds lockPointer
    let pointer: UnsafeMutablePointer<Value>
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock> // concurrency-allow: Mutex back-port for macOS 14; os_unfair_lock is the lock Synchronization.Mutex uses on Darwin, held only for the caller's short critical section

    init(_ initialValue: consuming Value) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: initialValue)
        lockPointer = .allocate(capacity: 1)
        lockPointer.initialize(to: os_unfair_lock()) // concurrency-allow: Mutex back-port for macOS 14; os_unfair_lock is the lock Synchronization.Mutex uses on Darwin, held only for the caller's short critical section
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
        lockPointer.deinitialize(count: 1)
        lockPointer.deallocate()
    }

    func lock() {
        os_unfair_lock_lock(lockPointer) // concurrency-allow: Mutex back-port for macOS 14; os_unfair_lock is the lock Synchronization.Mutex uses on Darwin, held only for the caller's short critical section
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Takes the lock. Returns the detector's table when the main thread waited for it longer than
    /// the table's limit (``BlockingKind/lockWaitLimitNanos``); an uncontended lock is one
    /// try-lock, as before, and only a contended one on the main thread is timed.
    func lockNotingMainThreadWait() -> BlockingViolationTable? {
        if tryLock() { return nil }
        return lockContended()
    }

    @inline(never)
    private func lockContended() -> BlockingViolationTable? {
        guard pthread_main_np() != 0 else {
            lock()
            return nil
        }
        let table = BlockingViolationTable.active
        let start = table.uptimeNanos()
        lock()
        return table.uptimeNanos() &- start > table.lockWaitLimitNanos ? table : nil
    }
    #endif

    func tryLock() -> Bool {
        os_unfair_lock_trylock(lockPointer) // concurrency-allow: Mutex back-port for macOS 14; os_unfair_lock is the lock Synchronization.Mutex uses on Darwin, held only for the caller's short critical section
    }

    func unlock() {
        os_unfair_lock_unlock(lockPointer) // concurrency-allow: Mutex back-port for macOS 14; os_unfair_lock is the lock Synchronization.Mutex uses on Darwin, held only for the caller's short critical section
    }
}
