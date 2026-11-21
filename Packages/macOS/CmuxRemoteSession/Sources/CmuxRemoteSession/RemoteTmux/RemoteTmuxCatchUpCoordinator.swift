public import Foundation

/// What a remote tmux connection's catch-up is waiting on, after its output stream fell a full
/// read bound behind.
///
/// A catch-up repaints every pane from a fresh capture and drops the pane's output up to that
/// capture, because the capture already shows its result. It waits on two kinds of pane: panes
/// with a seed whose capture has not arrived, tracked by seed ID, and panes still waiting for a
/// seed to start, whose output is dropped until it does. A pane waits for its seed either in the
/// reconnect queue or in this catch-up's own capture queue, which holds the captures the
/// connection has not sent yet because its command writer had no room for them. Only one
/// catch-up runs at a time. A request made while one runs is kept, and ``shouldStart`` turns
/// true when the last seed ends and no pane is still waiting for one.
///
/// Every operation is O(1) in the number of panes, amortized for the capture queue, so a
/// connection can ask ``shouldStart`` each time a seed ends without rescanning its seeds.
public struct RemoteTmuxCatchUpCoordinator: Equatable, Sendable {
    /// A catch-up was asked for and has not started yet.
    public private(set) var isRequested = false
    /// Seeds that drop their pane's output up to their capture.
    public private(set) var seedIDs: Set<UUID> = []
    /// Panes whose output is dropped until their next seed starts.
    public private(set) var panesAwaitingSeed: Set<Int> = []
    /// Panes whose catch-up capture has not been sent yet.
    public private(set) var panesAwaitingCapture: Set<Int> = []
    /// The order ``panesAwaitingCapture`` is sent in. A pane that left the set while queued is
    /// skipped when it reaches the front, so removing one costs nothing here.
    private var captureQueue = RemoteTmuxFIFO<Int>()

    /// Creates a coordinator with no request and nothing to wait on.
    public init() {}

    /// A catch-up is still waiting on tmux.
    public var isRunning: Bool {
        !seedIDs.isEmpty || !panesAwaitingSeed.isEmpty || !panesAwaitingCapture.isEmpty
    }

    /// A catch-up was asked for and none is running.
    public var shouldStart: Bool { isRequested && !isRunning }

    /// Asks for a catch-up. It starts once ``shouldStart`` is true.
    public mutating func request() {
        isRequested = true
    }

    /// Forgets a request that no longer needs a catch-up.
    public mutating func withdrawRequest() {
        isRequested = false
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

    /// Queues a catch-up capture for `paneId` and drops the pane's output until a seed starts.
    public mutating func queueCapture(forPane paneId: Int) {
        panesAwaitingSeed.insert(paneId)
        if panesAwaitingCapture.insert(paneId).inserted { captureQueue.append(paneId) }
    }

    /// Takes the next pane whose catch-up capture is still to be sent, oldest first.
    public mutating func nextQueuedCapture() -> Int? {
        while !captureQueue.isEmpty {
            let paneId = captureQueue.removeFirst()
            if panesAwaitingCapture.remove(paneId) != nil { return paneId }
        }
        return nil
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
        panesAwaitingCapture.remove(paneId)
    }

    /// Stops waiting on every pane not in `livePanes`.
    public mutating func retainPanes(_ livePanes: Set<Int>) {
        panesAwaitingSeed.formIntersection(livePanes)
        panesAwaitingCapture.formIntersection(livePanes)
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
