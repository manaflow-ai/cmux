import Testing
@testable import CmuxNextDaemon

/// `TabMovePlace`: a pending tab move keeps its place by the tabs beside it, and the store takes the move's index from
/// them each time it applies its pending intents again. One row for each part of the rule.
///
/// Decision of 2026-11-16: a moved tab that shows one slot off its place when the list changes under a pending move
/// is an order fault. The fault's own rows, with a person's hidden close, are in
/// `AMoveMadeWhileACloseIsHiddenKeepsItsSlotTests`. The rows here are the rule's other parts: they pass by design, and
/// no run at the code before the rule is their proof.
///
/// Each row: one pane `t a b c N` in a store with no daemon. A close of `a` that is not settled makes the list one
/// shorter while the move is made; the daemon's refusal of that close (`DaemonStore.rejectIntent`) makes it longer
/// again, so the move's index and the move's place name two different slots.
@MainActor
struct TabMovePlaceTests {
    private static let workspace = WorkspaceHandle(rawValue: 1)
    private static let screen = ScreenID(rawValue: 2)
    private static let pane = PaneID(rawValue: 3)
    /// `t a b c N`.
    private static let surfaces = (4...8).map { SurfaceID(rawValue: $0) }
    private static let letters = ["t", "a", "b", "c", "N"]

    private static func surface(_ letter: String) throws -> SurfaceID {
        let index = try #require(letters.firstIndex(of: letter), "setup: no tab \(letter)")
        return surfaces[index]
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let snapshot = WorkspaceSnapshot(
            id: workspace, key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: screen, active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: surfaces.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [snapshot]))
        return store
    }

    /// The pane's tabs as letters, in the store's order.
    private static func order(_ store: DaemonStore) throws -> String {
        let model = try #require(store.pane(Self.pane), "setup: the store has no pane")
        return model.tabs.map { tab in surfaces.firstIndex(of: tab.surface).map { letters[$0] } ?? "?" }.joined()
    }

    /// A pending move of the tab `letter` to `index` of the pane's list now.
    private static func move(_ letter: String, to index: Int, in store: DaemonStore) throws {
        let moved = try surface(letter)
        store.intend(.moveTab(surface: moved, toPane: pane, index: index), transaction: .generate())
    }

    /// The daemon's event that the tab `letter` closed.
    private static func daemonCloses(_ letter: String, in store: DaemonStore) throws {
        let closed = try surface(letter)
        _ = store.apply(.tabClosed(TabDelta(workspace: workspace, screen: screen, pane: pane, surface: closed, index: nil,
                                            entity: TabSnapshot(surface: closed))))
    }

    /// The tab that the moved tab stood before left the pane: the moved tab goes directly after its other neighbour.
    @Test func theTabGoesAfterItsOtherNeighbourWhenTheTabItStoodBeforeLeft() throws {
        let store = Self.store()
        let a = try Self.surface("a")
        let close = try #require(store.intendClose([a]), "setup: the close found no tab a")
        try Self.move("N", to: 2, in: store)
        try #require(try Self.order(store) == "tbNc", "setup: the move did not put N between b and c")

        try Self.daemonCloses("c", in: store)
        #expect(try Self.order(store) == "tbN")
        store.rejectIntent(close)
        // The move's index 2 names the slot before b in this list.
        #expect(try Self.order(store) == "tabN")
    }

    /// Both neighbours left the pane: the move's own index is all that is known, and the store takes it.
    @Test func theMoveKeepsItsIndexWhenBothNeighboursLeft() throws {
        let store = Self.store()
        let a = try Self.surface("a")
        let close = try #require(store.intendClose([a]), "setup: the close found no tab a")
        try Self.move("N", to: 2, in: store)
        try #require(try Self.order(store) == "tbNc", "setup: the move did not put N between b and c")

        try Self.daemonCloses("b", in: store)
        try Self.daemonCloses("c", in: store)
        #expect(try Self.order(store) == "tN")
        store.rejectIntent(close)
        #expect(try Self.order(store) == "taN")
    }

    /// A tab moved to the end stays the last tab when the list gets longer.
    @Test func aTabMovedToTheEndStaysLast() throws {
        let store = Self.store()
        let a = try Self.surface("a")
        let close = try #require(store.intendClose([a]), "setup: the close found no tab a")
        try Self.move("b", to: 3, in: store)
        try #require(try Self.order(store) == "tcNb", "setup: the move did not put b last")

        store.rejectIntent(close)
        // The move's index 3 names the slot before N in this list.
        #expect(try Self.order(store) == "tacNb")
    }

    /// A tab moved to the front stays the first tab when the tab it stood before left the pane.
    @Test func aTabMovedToTheFrontStaysFirstWhenTheTabItStoodBeforeLeft() throws {
        let store = Self.store()
        try Self.move("N", to: 0, in: store)
        try #require(try Self.order(store) == "Ntabc", "setup: the move did not put N first")

        try Self.daemonCloses("t", in: store)
        #expect(try Self.order(store) == "Nabc")
    }
}
