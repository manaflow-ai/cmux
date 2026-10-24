/// The owner of scheduled main-thread tasks (a batch queue, a control method), interned on a
/// ``MainTaskBoard`` once: when its queue is built, or off the main thread before a request is
/// queued. ``MainFrameBudget/run(_:owner:_:)`` publishes the index with atomic stores only, so
/// starting a task takes no lock and hashes no string on the main thread.
///
/// ```swift
/// let owner = work.budget.board.owner("DaemonStore.drain")
/// budget.run(.visible, owner: owner) { apply(slice) }
/// ```
public struct MainTaskOwner: Sendable, Hashable {
    /// The name the watchdog's records, the signposts and `debug.main_budget` show.
    public let name: String
    /// The board's index for ``name`` (index 0 is the board's "no task").
    let index: UInt32
}
