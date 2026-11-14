import CmuxRemoteSession
import Foundation

@MainActor
extension RemoteTmuxControlConnection {
    /// Starts a catch-up for a reader that fell a bound behind, or keeps the request until the
    /// catch-up in progress finishes. Before control mode is entered there is nothing to catch up:
    /// the attach seeds capture every pane anyway.
    func requestCatchUpAfterFallingBehind() {
        guard enterReceived else { return }
        catchUp.request()
        catchUpAfterFallingBehind()
    }

    /// Starts a catch-up that was requested while another one waited on tmux, once none does.
    /// Every way a seed leaves ``pendingPaneSeeds`` (finished, cancelled, its pane gone, or its
    /// window dropped from the topology) ends here, so the request cannot outlive the catch-up.
    func startRequestedCatchUp() {
        if catchUp.shouldStart { catchUpAfterFallingBehind() }
    }

    /// Whether a catch-up after falling behind was asked for and has not started.
    var catchUpRequested: Bool { catchUp.isRequested }

    /// Whether a catch-up started by ``catchUpAfterFallingBehind()`` is still waiting on tmux.
    var isCatchingUpAfterFallingBehind: Bool { catchUp.isRunning }

    /// Repaints every pane from tmux once the stream has fallen a full read bound behind.
    ///
    /// Output that arrives faster than it can be parsed and drawn is stale by the time it
    /// is drawn. A transport that held output through a network drop and then released it
    /// at once is the common case: hundreds of megabytes of it would otherwise be fed to
    /// every terminal before the user saw the current screen. A reconnect got there fast by
    /// throwing the backlog away with the connection and seeding each pane again; this does
    /// the same without leaving the connection. Every pane starts a full-history seed, as a
    /// reconnect does, and its live output up to the capture is dropped, because the capture
    /// already shows its result. A seed in progress whose capture has not arrived joins the
    /// catch-up instead and stops retaining its output too.
    ///
    /// Idle panes are repainted too: the backlog is still unparsed in the transport, so nothing
    /// says which panes it belongs to. Each full-history capture replaces the pane's scrollback
    /// with tmux's own history, as a reconnect does, so a pane keeps every line tmux kept.
    ///
    /// A pane still queued for its reconnect seed keeps its place in that queue, which bounds
    /// how much history is retained at once. Its output is dropped until the seed starts, and
    /// the seed drops output up to its capture, as a catch-up seed does.
    ///
    /// The capture replies queue behind the backlog in the stream, so the parser still reads
    /// through it, but nothing else is done with the dropped bytes. Only one catch-up runs
    /// at a time; ``catchUp`` keeps a pause during one, and ``startRequestedCatchUp()`` starts
    /// it when the last catch-up seed is gone and no queued pane is still waiting for one.
    func catchUpAfterFallingBehind() {
        guard connectionState == .connected, enterReceived, !catchUp.isRunning else { return }
        catchUp.begin()
        var joined = 0
        var joinedPaneIDs: Set<Int> = []
        for paneId in Array(pendingPaneSeeds.keys) {
            for index in pendingPaneSeeds[paneId]!.indices
            where pendingPaneSeeds[paneId]![index].canJoinCatchUp {
                releasePendingPaneSeedBytes(pendingPaneSeeds[paneId]![index].joinCatchUp())
                catchUp.track(seedID: pendingPaneSeeds[paneId]![index].id)
                joinedPaneIDs.insert(paneId)
                joined += 1
            }
        }
        var seeded = 0
        var queued = 0
        // A pane whose seeds all have their captures gets a new one too: the output still to
        // come is newer than those captures. Every capture goes out at once, so the order the
        // panes are visited in does not matter.
        var seenPaneIDs = joinedPaneIDs
        let queuedForReconnect = Set(pendingReconnectPaneIDs)
        for window in windowsByID.values {
            for paneId in window.paneIDsInOrder where seenPaneIDs.insert(paneId).inserted {
                if queuedForReconnect.contains(paneId) {
                    catchUp.awaitSeed(forPane: paneId)
                    queued += 1
                    continue
                }
                // Every other capture goes out now: a pane whose capture waited its turn would
                // draw the backlog.
                guard let seedID = capturePane(paneId: paneId, clearScrollback: true) else {
                    guard connectionState == .connected else { return }
                    continue
                }
                if let index = pendingPaneSeeds[paneId]?.firstIndex(where: { $0.id == seedID }) {
                    pendingPaneSeeds[paneId]![index].dropsPreCaptureOutput = true
                    catchUp.track(seedID: seedID)
                    seeded += 1
                }
            }
        }
        record("output-catch-up seeded=\(seeded) joined=\(joined) queued=\(queued)")
    }
}
