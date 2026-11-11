public import Foundation

/// What a remote tmux connection's catch-up is waiting on, after its output stream fell a full
/// read bound behind.
///
/// A catch-up repaints every pane from a fresh capture and drops the pane's output up to that
/// capture, because the capture already shows its result. It waits on two kinds of pane: panes
/// with a seed whose capture has not arrived, tracked by seed ID, and panes still queued for a
/// reconnect seed, whose output is dropped until that seed starts and takes over. Only one
/// catch-up runs at a time. A request made while one runs is kept, and ``shouldStart`` turns
/// true when the last seed ends and no pane is still waiting for one.
///
/// Every operation is O(1) in the number of panes, so a connection can ask ``shouldStart``
/// each time a seed ends without rescanning its seeds.
public struct RemoteTmuxCatchUpCoordinator: Equatable, Sendable {
    /// A catch-up was asked for and has not started yet.
    public private(set) var isRequested = false
    /// Seeds that drop their pane's output up to their capture.
    public private(set) var seedIDs: Set<UUID> = []
    /// Panes whose output is dropped until their next seed starts.
    public private(set) var panesAwaitingSeed: Set<Int> = []

    public init() {}

    /// A catch-up is still waiting on tmux.
    public var isRunning: Bool { !seedIDs.isEmpty || !panesAwaitingSeed.isEmpty }

    /// A catch-up was asked for and none is running.
    public var shouldStart: Bool { isRequested && !isRunning }

    /// Asks for a catch-up. It starts once ``shouldStart`` is true.
    public mutating func request() {
        isRequested = true
    }

    /// Starts a catch-up, which answers any request made so far.
    public mutating func begin() {
        isRequested = false
    }

    /// Makes the running catch-up wait on `seedID`.
    public mutating func track(seedID: UUID) {
        seedIDs.insert(seedID)
    }

    /// Drops `paneId`'s output until its next seed starts, for a pane that gets its seed later.
    public mutating func awaitSeed(forPane paneId: Int) {
        panesAwaitingSeed.insert(paneId)
    }

    /// Records a new seed for `paneId`. Returns whether the seed belongs to the catch-up and must
    /// drop the pane's output up to its capture: true when the pane was waiting for a seed.
    public mutating func seedStarted(_ seedID: UUID, forPane paneId: Int) -> Bool {
        guard panesAwaitingSeed.remove(paneId) != nil else { return false }
        seedIDs.insert(seedID)
        return true
    }

    /// Records that `seedID` finished, failed, or was discarded.
    public mutating func seedEnded(_ seedID: UUID) {
        seedIDs.remove(seedID)
    }

    /// Stops waiting on a pane that left the session.
    public mutating func paneRemoved(_ paneId: Int) {
        panesAwaitingSeed.remove(paneId)
    }

    /// Stops waiting on every pane not in `livePanes`.
    public mutating func retainPanes(_ livePanes: Set<Int>) {
        panesAwaitingSeed.formIntersection(livePanes)
    }

    /// Whether `paneId`'s output is dropped because the pane is waiting for its seed.
    public func dropsOutput(forPane paneId: Int) -> Bool {
        panesAwaitingSeed.contains(paneId)
    }

    /// Forgets the request and everything the catch-up waited on, for a connection whose
    /// pending seeds were all discarded.
    public mutating func reset() {
        self = RemoteTmuxCatchUpCoordinator()
    }
}
