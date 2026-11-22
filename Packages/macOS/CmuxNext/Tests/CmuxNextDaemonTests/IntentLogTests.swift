import Foundation
import Testing
@testable import CmuxNextDaemon

/// The confirmed mirror plus one ordered intent log (plans/cmux-next/
/// OWNERSHIP-PRINCIPLES.md, "Clients are projections"): a pending move
/// stays visible until it settles, and the mirror holds the daemon's result
/// once it does.
@MainActor @Suite struct IntentLogTests {
    private func loaded() throws -> (DaemonStore, DaemonTree) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        return (store, tree)
    }

    private func entity(_ surface: SurfaceID, in tree: DaemonTree) throws -> TabSnapshot {
        try #require(tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface == surface })
    }

    private func moved(_ surface: SurfaceID, to pane: PaneID, index: Int, in tree: DaemonTree,
                       transaction: ClientTransactionID? = nil) throws -> DaemonEvent {
        .tabChanged(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: try entity(surface, in: tree),
                             clientTransactionID: transaction))
    }

    /// `tree` with surface 3 moved to the front of pane 7.
    private func treeAfterMove(_ tree: DaemonTree) -> DaemonTree {
        var next = tree
        for (w, workspace) in next.workspaces.enumerated() {
            for (s, screen) in workspace.screens.enumerated() {
                for (p, pane) in screen.panes.enumerated() {
                    next.workspaces[w].screens[s].panes[p].tabs = pane.tabs.filter { $0.surface != 3 }
                    if pane.id == 7, let tab = tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first(where: { $0.surface == 3 }) {
                        next.workspaces[w].screens[s].panes[p].tabs.insert(tab, at: 0)
                    }
                }
            }
        }
        return next
    }

    /// The reply came back (no echo), but the daemon's events for the move
    /// are not applied yet, and a resync that started before the reply
    /// lands with the pre-move tree. The move is not settled, so it must
    /// stay visible; dropping it at "the next snapshot" showed the tab back
    /// in its old pane until some later event.
    @Test func anUnsettledMoveSurvivesASnapshotThatPredatesIt() throws {
        let (store, tree) = try loaded()
        var settled: [IntentSettlement] = []
        store.onIntentSettled = { _, how in settled.append(how) }
        store.intend(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "tx")
        store.noteSettled("tx", at: 10)
        store.apply(snapshot: tree)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
        #expect(settled.isEmpty)

        // The move's own events (no echo: an older daemon) reach the barrier.
        store.apply(batch: [DaemonEventEnvelope(sequence: 10, event: try moved(3, to: 7, index: 0, in: tree))])
        #expect(settled == [.applied])
        #expect(!store.hasPendingIntents)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
    }

    /// P1: a move inside one pane is echoed as the tab's `tab-changed` with
    /// its new index in the same pane. The confirmed mirror must apply it,
    /// or the tab shows at its old place once the intent leaves the log.
    @Test func tabChangedAppliesTheIndexInsideThePane() throws {
        let (store, tree) = try loaded()
        #expect(store.pane(4)?.tabs.map(\.surface) == [3, 13])
        store.apply(try moved(3, to: 4, index: 1, in: tree))
        #expect(store.pane(4)?.tabs.map(\.surface) == [13, 3])
    }

    @Test func anInPaneMoveSettlesOnItsEchoWithoutFlickering() throws {
        let (store, tree) = try loaded()
        store.intend(.moveTab(surface: 3, toPane: 4, index: 1), transaction: "tx")
        #expect(store.pane(4)?.tabs.map(\.surface) == [13, 3])
        store.apply(batch: [DaemonEventEnvelope(sequence: 4, event: try moved(3, to: 4, index: 1, in: tree, transaction: "tx"))])
        #expect(!store.hasPendingIntents)
        #expect(store.pane(4)?.tabs.map(\.surface) == [13, 3])
    }

    @Test func aRejectedMoveShowsTheConfirmedPlacementAgain() throws {
        let (store, _) = try loaded()
        var settled: [IntentSettlement] = []
        store.onIntentSettled = { _, how in settled.append(how) }
        store.intend(.moveTab(surface: 3, toPane: 7, index: 1), transaction: "tx")
        #expect(store.pane(7)?.tabs.map(\.surface) == [6, 3])
        store.rejectIntent("tx")
        #expect(store.pane(4)?.tabs.map(\.surface) == [3, 13])
        #expect(store.pane(7)?.tabs.map(\.surface) == [6])
        // A late reply or echo never settles it again.
        store.noteSettled("tx", at: 0)
        store.rejectIntent("tx")
        #expect(settled == [.rejected])
    }

    /// An echo the inbox collapsed into `tree-changed` forces a resync: the
    /// intent settles only once the snapshot holding the move is applied.
    @Test func anEchoThatNeedsAResyncSettlesWithTheSnapshot() throws {
        let (store, tree) = try loaded()
        store.intend(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "tx")
        #expect(store.apply(batch: [DaemonEventEnvelope(sequence: 5, event: .treeChanged(transaction: "tx"))]) == .resync)
        #expect(store.hasPendingIntents)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        store.apply(snapshot: treeAfterMove(tree))
        store.snapshotBarrier = 6
        store.advanceAppliedSequence(to: 6)
        #expect(!store.hasPendingIntents)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
    }

    /// A Cloud machine's link replaces its `DaemonConnection`, whose event
    /// sequences restart from a new serial below the old ones. A reply
    /// barrier from the lost connection must not settle against the new
    /// numbering; the move settles with the new connection's first snapshot.
    @Test func aReplyFromALostConnectionSettlesWithTheNextSnapshot() throws {
        let (store, tree) = try loaded()
        store.advanceAppliedSequence(to: 5 << 40)
        store.intend(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "tx")
        store.noteSettled("tx", at: (5 << 40) | 9)
        store.beginConnection()
        #expect(store.appliedSequence == 0)
        // The new connection's first events do not settle it.
        store.apply(batch: [DaemonEventEnvelope(sequence: (1 << 40) | 1, event: .titleChanged(surface: 6, title: "vim"))])
        #expect(store.hasPendingIntents)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        // Its first snapshot (requested after the reply) holds the move.
        store.apply(snapshot: treeAfterMove(tree))
        #expect(!store.hasPendingIntents)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
    }

    @Test func pendingIntentsStayOverDaemonEventsInOrder() throws {
        let (store, tree) = try loaded()
        store.intend(.moveTab(surface: 3, toPane: 7, index: 1), transaction: "a")
        store.intend(.moveTab(surface: 13, toPane: 7, index: 0), transaction: "b")
        #expect(store.pane(7)?.tabs.map(\.surface) == [13, 6, 3])
        #expect(store.pane(4)?.tabs.isEmpty == true)
        // An unrelated event applies to the confirmed records under the overlay.
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .titleChanged(surface: 6, title: "vim"))])
        #expect(store.pane(7)?.tabs.map(\.surface) == [13, 6, 3])
        // "a" settles by its echo; "b" stays on top of the new confirmed state.
        store.apply(batch: [DaemonEventEnvelope(sequence: 4, event: try moved(3, to: 7, index: 1, in: tree, transaction: "a"))])
        #expect(store.pendingIntents == [.moveTab(surface: 13, toPane: 7, index: 0)])
        #expect(store.pane(7)?.tabs.map(\.surface) == [13, 6, 3])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// Conservation: a move whose tab or target is gone does nothing.
    @Test func aMoveOfAMissingTabOrIntoAMissingPaneIsANoOp() throws {
        let (store, _) = try loaded()
        store.intend(.moveTab(surface: 999, toPane: 7, index: 0), transaction: "a")
        store.intend(.moveTab(surface: 3, toPane: 999, index: 0), transaction: "b")
        #expect(store.pane(4)?.tabs.map(\.surface) == [3, 13])
        #expect(store.pane(7)?.tabs.map(\.surface) == [6])
        // The tab closes on the daemon while its move is pending.
        store.intend(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "c")
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .tabClosed(TabDelta(
            workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: TabSnapshot(surface: 3))))])
        #expect(store.pane(7)?.tabs.map(\.surface) == [6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// The debug-build single-writer check: a record write outside daemon
    /// apply and the overlay is reported by the next allowed writer.
    @Test func aMirrorWriteOutsideApplyIsReported() throws {
        let (store, _) = try loaded()
        #expect(store.mirrorViolations.isEmpty)
        _ = try #require(store.pane(4)).removeTab(surface: 13)
        store.apply(.titleChanged(surface: 3, title: "x"))
        #if DEBUG
        #expect(store.mirrorViolations.count == 1)
        #else
        #expect(store.mirrorViolations.isEmpty)
        #endif
    }
}
