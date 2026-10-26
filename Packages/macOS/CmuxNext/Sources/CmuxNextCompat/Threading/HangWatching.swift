/// Watches a unit of work on the calling thread for a hang: Chrome's `base::WatchHangsInScope`
/// (base/threading/hang_watcher.h), for modules below CmuxNextControl, which implements it
/// (`ThreadHangWatcher`).
///
/// ``enter(_:deadline:)`` arms the calling thread's scope; ``leave(_:)`` with its token ends it on
/// the same thread. A scope still armed past its deadline is reported once, with the thread's name
/// and stack. Scopes nest: the inner deadline applies until it leaves, then the outer one again.
/// Both calls are a clock read and a few atomic stores, with no lock and no system call, so they
/// fit a per-chunk or per-job path. Put a scope around work, never around a wait for input
/// (a `read(2)`, a queue wait): an idle wait is not a hang.
public protocol HangWatching: Sendable {
    /// Arms a scope on the calling thread.
    ///
    /// - Parameters:
    ///   - name: What the work is, as it shows in the hang report (a catalog literal, never a person's text).
    ///   - deadline: How long the work may run from now before it is a hang.
    /// - Returns: The token to pass to ``leave(_:)`` on this thread.
    func enter(_ name: StaticString, deadline: Duration) -> HangWatchToken

    /// Ends the scope `token` came from and re-arms the scope it was nested in, if any.
    ///
    /// - Parameter token: What ``enter(_:deadline:)`` returned on this thread.
    func leave(_ token: HangWatchToken)
}

extension HangWatching {
    /// Runs `body` inside a scope named `name` that hangs after `deadline`.
    ///
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    @inlinable
    public func watching<Result, Failure: Error>(_ name: StaticString, deadline: Duration,
                                                 _ body: () throws(Failure) -> Result) throws(Failure) -> Result {
        let token = enter(name, deadline: deadline)
        defer { leave(token) }
        return try body()
    }
}

/// What a ``HangWatching`` scope saved when it armed: the thread's slot and the scope it replaced,
/// which ``HangWatching/leave(_:)`` restores. Its words belong to the implementation.
public struct HangWatchToken: Sendable, Equatable {
    /// The address of the thread's slot; 0 when the thread has none (the slot table is full).
    public let slot: UInt
    /// The enclosing scope's deadline (0: none).
    public let previousDeadline: UInt64
    /// The enclosing scope's packed name.
    public let previousName: UInt64
    /// When the enclosing scope armed.
    public let previousStart: UInt64

    /// A token with the given words (implementations of ``HangWatching`` make these).
    public init(slot: UInt, previousDeadline: UInt64, previousName: UInt64, previousStart: UInt64) {
        self.slot = slot
        self.previousDeadline = previousDeadline
        self.previousName = previousName
        self.previousStart = previousStart
    }

    /// The token of a scope nothing watches; leaving it does nothing.
    public static let unwatched = HangWatchToken(slot: 0, previousDeadline: 0, previousName: 0, previousStart: 0)
}
