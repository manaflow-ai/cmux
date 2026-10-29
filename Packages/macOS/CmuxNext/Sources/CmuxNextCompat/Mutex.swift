internal import CmuxSafeConcurrency
#if (DEBUG || CMUX_BLOCKING_CHECKS) && canImport(Darwin)
internal import Darwin
#endif

/// A value that only one thread at a time can read or change, with the API of
/// `Synchronization.Mutex` (macOS 15) so that cmux-next runs on macOS 14
/// (plans/cmux-next/macos-floor.md). It is CmuxSafeConcurrency's portable `Mutex`
/// (`os_unfair_lock`, the lock the system type uses on Darwin; on Linux a pthread
/// mutex, as Chromium's base/synchronization/lock_impl_posix.cc) with the
/// main-thread blocking detector watching its waits on both. Import this module
/// instead of `Synchronization`; call sites do not change.
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
    /// In Debug and bench-checks builds (Nightly to come) a wait for the lock longer than
    /// ``BlockingKind/lockWaitLimitNanos`` on the main thread, or in a `BackgroundWork` lane item (a
    /// ``BlockingContext/laneSync`` site; a ``BlockingContext/cpuLane`` one in a `.cpu` item), is recorded, with
    /// the wait as its time, by the blocking detector at the caller's `fileID`:`line` (never a trap: the wait
    /// includes scheduling time).
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
        // A long main-thread or lane wait is recorded after the unlock (Debug and bench-checks builds;
        // Nightly to come).
        return try base.withLock(observedBy: LockWaitObserver(fileID: fileID, line: line), body)
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
/// The blocking detector watching one `withLock` call: it times a contended wait on the main thread or in a
/// `BackgroundWork` lane item, `.cpu` included (Chrome's `ScopedDisallowBaseSyncPrimitives` covers a lock wait in
/// a `MayBlock()` task too, and `ScopedDisallowBlocking` one in any other task) with the active table's clock, and
/// records a wait past ``BlockingKind/lockWaitLimitNanos`` at the caller's site once the lock is released. Waits
/// on other threads are not timed.
struct LockWaitObserver: MutexWaitObserver {
    /// A timed wait: the table and clock it uses, when it began, and where a long one is recorded
    /// (``BlockingContext/main``, ``BlockingContext/laneSync`` or ``BlockingContext/cpuLane``).
    struct Wait {
        let table: BlockingViolationTable
        let start: UInt64
        let context: BlockingContext
    }

    /// A wait past the limit, reported once the lock is released.
    struct Report {
        let table: BlockingViolationTable
        let nanos: UInt64
        let context: BlockingContext
    }

    let fileID: StaticString
    let line: UInt

    func waitWillBegin() -> Wait? {
        let onMain = pthread_main_np() != 0
        guard let context = onMain ? BlockingContext.main : BlockingContext.laneLockWaitViolation() else { return nil }
        let table = BlockingViolationTable.active
        return Wait(table: table, start: table.uptimeNanos(), context: context)
    }

    func waitDidEnd(_ wait: Wait) -> Report? {
        let nanos = wait.table.uptimeNanos() &- wait.start
        guard nanos > wait.table.lockWaitLimitNanos else { return nil }
        return Report(table: wait.table, nanos: nanos, context: wait.context)
    }

    func lockReleased(_ report: Report) {
        if report.context == .main {
            report.table.mainThreadWaitedForLock(fileID: fileID, line: line, nanos: report.nanos)
        } else {
            report.table.laneWaitedForLock(in: report.context, fileID: fileID, line: line, nanos: report.nanos)
        }
    }
}
#endif
