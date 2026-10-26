/// Watches a unit of work on the calling thread for a hang: Chrome's `base::WatchHangsInScope`
/// (base/threading/hang_watcher.h). ``enter(_:deadline:)`` arms the thread's slot with a deadline,
/// ``leave(_:)`` puts back what the slot held before, so scopes nest as in Chrome. A watcher thread
/// reports a slot whose deadline passes (it samples that thread); the work itself is never stopped.
///
/// Wrap only work the thread does itself: never a `read(2)` that waits for input, a queue wait or a
/// lock wait for another thread, which are idle time, not a hang.
///
/// The app builds one watcher and passes it by `init`; `nil` watches nothing and changes nothing.
///
/// ```swift
/// let token = hangs?.enter("lane.files", deadline: .seconds(5))
/// defer { if let token { hangs?.leave(token) } }
/// ```
public protocol HangWatching: Sendable {
    /// Arms the calling thread's slot: the work from now on must end within `deadline`.
    ///
    /// - Parameters:
    ///   - name: what the work is (`lane.files`, `daemon.line`), shown in the hang report.
    ///   - deadline: how long the work may run before it is reported as a hang.
    /// - Returns: the token ``leave(_:)`` takes on the same thread.
    func enter(_ name: StaticString, deadline: Duration) -> HangWatchToken

    /// Ends the scope `token` opened on this thread and puts back the enclosing scope's deadline.
    func leave(_ token: HangWatchToken)
}

/// What one ``HangWatching/enter(_:deadline:)`` saved: the thread's slot and the deadline it held before,
/// which ``HangWatching/leave(_:)`` puts back (Chrome's `WatchHangsInScope::previous_deadline_`).
public struct HangWatchToken: Sendable, Equatable {
    /// The thread's slot, or -1 when every slot was taken and the scope is not watched.
    public let slot: Int32
    /// The slot's deadline before this scope (0: no enclosing scope).
    public let previousDeadline: UInt64

    public init(slot: Int32, previousDeadline: UInt64) {
        self.slot = slot
        self.previousDeadline = previousDeadline
    }
}
