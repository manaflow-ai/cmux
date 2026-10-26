internal import CmuxSafeConcurrency

/// A value that only one thread at a time can read or change, with the API of `Synchronization.Mutex` (macOS 15 /
/// iOS 18) on the macOS 14 / iOS 17 floor: CmuxSafeConcurrency's portable `Mutex` (`os_unfair_lock`) with the
/// process's ``BlockingCallHook`` watching its contended waits, as CmuxNextCompat's `Mutex` is for the app's own
/// modules. In the app a main-thread wait longer than the detector's limit is recorded at the caller's
/// `fileID`:`line`; an uncontended lock is one try-lock and reads no hook.
public struct Mutex<Value: ~Copyable>: ~Copyable {
    private let base: CmuxSafeConcurrency.Mutex<Value>

    /// Makes a mutex that holds `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        base = CmuxSafeConcurrency.Mutex(initialValue)
    }

    /// Runs `body` with exclusive access to the value and returns its result. Do not call `withLock` on the same
    /// mutex from inside `body`: the lock is not recursive.
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
        try base.withLock(observedBy: HookedLockWait(slot: .process, fileID: fileID, line: line), body)
    }

    /// Runs `body` with exclusive access to the value when the lock is free now; returns nil without running `body`
    /// when another thread holds it.
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        try base.withLockIfAvailable(body)
    }
}

extension Mutex: Sendable where Value: ~Copyable {}

/// One `withLock` call's contended wait as the hook in `slot` sees it: the hook is read only when the lock is taken,
/// and the wait it timed is reported after the unlock, so a report never runs under the lock.
struct HookedLockWait: MutexWaitObserver {
    let slot: BlockingCallHookSlot
    let fileID: StaticString
    let line: UInt

    func waitWillBegin() -> (hook: any BlockingCallHook, start: UInt64)? {
        guard let hook = slot.installed, let start = hook.lockWaitWillBegin() else { return nil }
        return (hook, start)
    }

    func waitDidEnd(_ wait: (hook: any BlockingCallHook, start: UInt64)) -> (hook: any BlockingCallHook, nanos: UInt64)? {
        guard let nanos = wait.hook.lockWaitDidEnd(startedAt: wait.start) else { return nil }
        return (wait.hook, nanos)
    }

    func lockReleased(_ report: (hook: any BlockingCallHook, nanos: UInt64)) {
        report.hook.lockWaited(fileID: fileID, line: line, nanos: report.nanos)
    }
}
