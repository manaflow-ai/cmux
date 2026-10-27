/// Watches the waits of ``Mutex/withLock(observedBy:_:)`` for a contended lock: a seam a caller injects
/// (cmux-next's main-thread blocking detector times the main thread's waits with it). An uncontended
/// lock is one try-lock and calls nothing here.
///
/// The calls come in order on the waiting thread: ``waitWillBegin()`` before the wait, without the
/// lock; ``waitDidEnd(_:)`` with the lock just taken; ``lockReleased(_:)`` after the caller's body ran
/// and the lock was released, so a report never runs under the lock.
public protocol MutexWaitObserver {
    /// What ``waitWillBegin()`` keeps for ``waitDidEnd(_:)``: a start time, for example.
    associatedtype Wait
    /// What ``waitDidEnd(_:)`` hands to ``lockReleased(_:)``: a measured wait, for example.
    associatedtype Report

    /// Another thread holds the lock and this thread is about to wait for it. Returns what to keep for
    /// ``waitDidEnd(_:)``, or nil to wait unobserved.
    func waitWillBegin() -> Wait?

    /// The observed wait ended: this thread holds the lock. Returns what to report once the lock is
    /// released, or nil for nothing. Keep it short: the lock is held.
    func waitDidEnd(_ wait: Wait) -> Report?

    /// The lock taken after an observed wait was released; `report` is what ``waitDidEnd(_:)`` returned.
    func lockReleased(_ report: Report)
}
