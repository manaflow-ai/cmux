internal import CmuxSafeConcurrency
#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
#endif

/// A value that only one thread at a time can read or change, with the API of
/// `Synchronization.Mutex` (macOS 15) so that cmux-next runs on macOS 14
/// (plans/cmux-next/macos-floor.md). It is CmuxSafeConcurrency's portable `Mutex`
/// (`os_unfair_lock`, the lock the system type uses on Darwin) with the
/// main-thread blocking detector watching its waits. Import this module instead
/// of `Synchronization`; call sites do not change.
public struct Mutex<Value: ~Copyable>: ~Copyable {
    private let base: CmuxSafeConcurrency.Mutex<Value>

    /// Makes a mutex that holds `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        base = CmuxSafeConcurrency.Mutex(initialValue)
    }

    /// Runs `body` with exclusive access to the value and returns its result.
    /// Do not call `withLock` on the same mutex from inside `body`: the lock
    /// is not recursive.
    ///
    /// In Debug and bench-checks builds (Nightly to come) a main-thread wait for the lock longer than
    /// ``BlockingKind/lockWaitLimitNanos`` is recorded, with the wait as its time, by the main-thread
    /// blocking detector at the caller's `fileID`:`line` (never a trap: the wait includes scheduling time).
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
        // A long main-thread wait is recorded after the unlock (Debug and bench-checks builds; Nightly to come).
        return try base.withLock(observedBy: MainThreadLockWaitObserver(fileID: fileID, line: line), body)
        #else
        return try base.withLock(body)
        #endif
    }

    /// Runs `body` with exclusive access to the value when the lock is free
    /// now; returns nil without running `body` when another thread holds it.
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        try base.withLockIfAvailable(body)
    }
}

extension Mutex: Sendable where Value: ~Copyable {}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// The main-thread blocking detector watching one `withLock` call: it times a contended wait on the main
/// thread with the active table's clock and records a wait past ``BlockingKind/lockWaitLimitNanos`` at the
/// caller's site once the lock is released. Waits on other threads are not timed.
struct MainThreadLockWaitObserver: MutexWaitObserver {
    let fileID: StaticString
    let line: UInt

    func waitWillBegin() -> (table: BlockingViolationTable, start: UInt64)? {
        guard pthread_main_np() != 0 else { return nil }
        let table = BlockingViolationTable.active
        return (table, table.uptimeNanos())
    }

    func waitDidEnd(_ wait: (table: BlockingViolationTable, start: UInt64)) -> (table: BlockingViolationTable, nanos: UInt64)? {
        let nanos = wait.table.uptimeNanos() &- wait.start
        return nanos > wait.table.lockWaitLimitNanos ? (wait.table, nanos) : nil
    }

    func lockReleased(_ report: (table: BlockingViolationTable, nanos: UInt64)) {
        report.table.mainThreadWaitedForLock(fileID: fileID, line: line, nanos: report.nanos)
    }
}
#endif
