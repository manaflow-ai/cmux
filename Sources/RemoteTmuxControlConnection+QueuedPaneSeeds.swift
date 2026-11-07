import Foundation

/// Panes waiting for a first seed, in arrival order. Membership is a set and the front is a
/// moving index, so queueing every pane of a large host and draining it are both linear;
/// an array's `contains` and `removeFirst` made each quadratic.
struct RemoteTmuxPaneSeedQueue: Equatable, ExpressibleByArrayLiteral {
    private var order: [Int] = []
    private var head = 0
    private var members: Set<Int> = []

    init(arrayLiteral elements: Int...) { elements.forEach { append($0) } }

    var isEmpty: Bool { members.isEmpty }
    var count: Int { members.count }
    var elements: [Int] { Array(order[head...]) }
    func contains(_ paneId: Int) -> Bool { members.contains(paneId) }

    mutating func append(_ paneId: Int) {
        guard members.insert(paneId).inserted else { return }
        order.append(paneId)
    }

    mutating func popFirst() -> Int? {
        guard head < order.count else { return nil }
        let paneId = order[head]
        head += 1
        members.remove(paneId)
        if head > 64, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
        return paneId
    }

    /// Drops waiting panes that match. Runs when panes close, not per queued pane.
    mutating func removeAll(where shouldRemove: (Int) -> Bool) {
        order = order[head...].filter { !shouldRemove($0) }
        head = 0
        members = Set(order)
    }

    mutating func removeAll() { self = [] }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elements == rhs.elements }
}

/// First seeds for panes that just mounted, started a few at a time.
///
/// A mirror seeds each pane when its surface mounts. On a host with hundreds of windows
/// every pane of every workspace mounts in the same main-actor turn, and each seed is about
/// a dozen commands plus a capture of the pane's history. Sent together, their captures
/// arrive together and overrun the seed byte budget, and every other command waits behind
/// megabytes of history on a slow link. So mounted panes wait here and start as earlier
/// seeds finish, the same way
/// a reconnect's reseed is paced (``pumpReconnectPaneSeeds()``).
@MainActor
extension RemoteTmuxControlConnection {
    /// How many queued first seeds may be in flight at once.
    nonisolated static let maximumConcurrentQueuedPaneSeeds = 4

    /// Seeds `paneId` once a slot is free. A pane already waiting, or whose queued seed is
    /// in flight, is not queued twice. The in-flight scan is over at most
    /// ``maximumConcurrentQueuedPaneSeeds`` entries.
    func queuePaneSeed(paneId: Int) {
        guard !queuedPaneSeedPaneIDs.contains(paneId),
              !queuedPaneSeedIDs.values.contains(paneId) else { return }
        queuedPaneSeedPaneIDs.append(paneId)
        pumpQueuedPaneSeeds()
    }

    func pumpQueuedPaneSeeds() {
        guard connectionState == .connected else { return }
        while queuedPaneSeedIDs.count < Self.maximumConcurrentQueuedPaneSeeds,
              !queuedPaneSeedPaneIDs.isEmpty
        {
            guard let paneId = queuedPaneSeedPaneIDs.popFirst() else { return }
            // No seed started. A full seed budget has already handed the pane to the budget
            // recovery, and a refused write has begun a reconnect that reseeds every pane, so
            // the pane is not put back.
            guard let seedID = seedPane(paneId: paneId, clearScrollback: true) else { return }
            queuedPaneSeedIDs[seedID] = paneId
        }
    }

    /// Frees the slot a finished, failed or discarded queued seed held.
    func resolveQueuedPaneSeed(_ seedID: UUID) {
        guard queuedPaneSeedIDs.removeValue(forKey: seedID) != nil else { return }
        pumpQueuedPaneSeeds()
    }

    /// Forgets every waiting pane and in-flight slot, for a stream that is going away.
    func discardQueuedPaneSeeds() {
        queuedPaneSeedPaneIDs.removeAll()
        queuedPaneSeedIDs.removeAll(keepingCapacity: false)
    }
}
