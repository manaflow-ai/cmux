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

    /// The reply came back (no echo), but the daemon's events for the move
    /// are not applied yet, and a resync that started before the reply
    /// lands with the pre-move tree. The move is not settled, so it must
    /// stay visible; dropping it at "the next snapshot" showed the tab back
    /// in its old pane until some later event.
    @Test func anUnsettledMoveSurvivesASnapshotThatPredatesIt() throws {
        let (store, tree) = try loaded()
        store.applyOptimistic(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "tx")
        store.settleOptimistic("tx")
        store.apply(snapshot: tree)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
    }

    /// P1: a move inside one pane is echoed as the tab's `tab-changed` with
    /// its new index in the same pane. The confirmed mirror must apply it,
    /// or the tab shows at its old place once the intent leaves the log.
    @Test func tabChangedAppliesTheIndexInsideThePane() throws {
        let (store, tree) = try loaded()
        #expect(store.pane(4)?.tabs.map(\.surface) == [3, 13])
        let delta = TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 1, entity: try entity(3, in: tree))
        store.apply(.tabChanged(delta))
        #expect(store.pane(4)?.tabs.map(\.surface) == [13, 3])
    }
}
