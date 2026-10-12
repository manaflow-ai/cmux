import Foundation

/// First seeds for panes that just mounted, started a few at a time.
///
/// A mirror seeds each pane when its surface mounts. On a host with hundreds of windows
/// every pane of every workspace mounts in the same main-actor turn, and each seed is about
/// a dozen commands plus a capture of the pane's history. Sent together they queue more
/// stdin than the control writer allows, which reconnects the stream, and the reconnect
/// mounts them all again. Their captures would also arrive together and overrun the seed
/// byte budget. So mounted panes wait here and start as earlier seeds finish, the same way
/// a reconnect's reseed is paced (``pumpReconnectPaneSeeds()``).
@MainActor
extension RemoteTmuxControlConnection {
    /// How many queued first seeds may be in flight at once.
    nonisolated static let maximumConcurrentQueuedPaneSeeds = 4

    /// Seeds `paneId` once a slot is free. A pane already waiting, or whose queued seed is
    /// in flight, is not queued twice.
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
            let paneId = queuedPaneSeedPaneIDs.removeFirst()
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
        queuedPaneSeedPaneIDs.removeAll(keepingCapacity: false)
        queuedPaneSeedIDs.removeAll(keepingCapacity: false)
    }
}
