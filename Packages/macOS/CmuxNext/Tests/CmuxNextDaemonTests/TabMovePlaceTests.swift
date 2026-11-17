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
/// Each row: one pane in a store with no daemon (`t a b c N` when the row names no other). A close of `a` that is not
/// settled makes the list one shorter while the move is made; the daemon's refusal of that close
/// (`DaemonStore.rejectIntent`) makes it longer again, so the move's index and the move's place name two different
/// slots.
///
/// The last three rows are for a refusal of the daemon and for a held close (decision of 2026-11-17: the store's
/// place is the place that the daemon's own move gives, where the store can know it). No row sends a command: the
/// daemon's order in a row's comment is the move to the index that `DaemonStore.daemonMoveIndex` gives the command,
/// made by hand on the daemon's list, and the row reads that index. The closed tab of these rows is right of the
/// moved tab's place. A refused sent close of a tab left of the place is a row of
/// `AMoveMadeWhileACloseIsHiddenKeepsItsSlotTests`: there the store's order is not the daemon's.
@MainActor
struct TabMovePlaceTests {
    private static let workspace = WorkspaceHandle(rawValue: 1)
    private static let screen = ScreenID(rawValue: 2)
    private static let pane = PaneID(rawValue: 3)
    /// The tabs that a row's pane can have, each by its letter. `N` and `M` are new tabs.
    private static let surfaces = (4...10).map { SurfaceID(rawValue: $0) }
    private static let letters = ["t", "a", "b", "c", "d", "N", "M"]

    private static func surface(_ letter: String) throws -> SurfaceID {
        let index = try #require(letters.firstIndex(of: letter), "setup: no tab \(letter)")
        return surfaces[index]
    }

    /// A store with the one pane `tabs` (a letter for each tab, in the pane's order).
    private static func store(_ tabs: String = "tabcN") -> DaemonStore {
        let store = DaemonStore()
        let listed = tabs.compactMap { letter in letters.firstIndex(of: String(letter)).map { surfaces[$0] } }
        let snapshot = WorkspaceSnapshot(
            id: workspace, key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: screen, active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: listed.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [snapshot]))
        return store
    }

    /// The pane's tabs as letters, in the store's order.
    private static func order(_ store: DaemonStore) throws -> String {
        let model = try #require(store.pane(Self.pane), "setup: the store has no pane")
        return model.tabs.map { tab in surfaces.firstIndex(of: tab.surface).map { letters[$0] } ?? "?" }.joined()
    }

    /// A pending move of the tab `letter` to `index` of the pane's list now; its transaction.
    @discardableResult
    private static func move(_ letter: String, to index: Int, in store: DaemonStore) throws -> ClientTransactionID {
        let moved = try surface(letter), transaction = ClientTransactionID.generate()
        store.intend(.moveTab(surface: moved, toPane: pane, index: index), transaction: transaction)
        return transaction
    }

    /// The index that the command to the daemon has for a move of the tab `letter` to `index` of the pane's list now.
    private static func commandIndex(_ letter: String, to index: Int, in store: DaemonStore) throws -> Int {
        let model = try #require(store.pane(Self.pane), "setup: the store has no pane")
        return store.daemonMoveIndex(index, moving: try surface(letter), in: model).final
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

    /// A close that was sent, and that the daemon refuses, of the tab between the moved tab's two neighbours. Pane
    /// `t a b c d N`. The close of `c` is sent (the store does not hold it back) and not answered. The new tab `N`
    /// moves right after `b` (index 3 of `t a b d`), and its command has the index 3: a sent close does not count in
    /// it. The daemon refuses the close, so its list is `t a b c d N`, and its move to index 3 gives `t a b N c d`.
    /// The store shows that order at the refusal, and not `t a b c N d` until the move's event.
    @Test func aRefusedSentCloseBetweenTheNeighboursLeavesTheTabWhereTheDaemonsMovePutsIt() throws {
        let store = Self.store("tabcdN")
        let close = try #require(store.intendClose([try Self.surface("c")]), "setup: the close found no tab c")
        try #require(try Self.commandIndex("N", to: 3, in: store) == 3, "setup: the command's index is not 3")
        try Self.move("N", to: 3, in: store)
        try #require(try Self.order(store) == "tabNd", "setup: the move did not put N between b and d")

        store.rejectIntent(close)
        #expect(try Self.order(store) == "tabNcd")
    }

    /// The same steps with a close that the store holds back from the daemon while a read decides
    /// (`DaemonStore.holdTabs`). The held tab counts in the command's index (4: the daemon's list has `c`), so the
    /// daemon's move gives `t a b c N d`. The hold is rolled back (the read found a program): the store shows that
    /// order. The moved tab's neighbour on its left is the held tab, which the visible list does not have.
    @Test func aHeldCloseBetweenTheNeighboursThatIsRolledBackLeavesTheTabAfterTheHeldTab() throws {
        let store = Self.store("tabcdN")
        let c = try Self.surface("c")
        let held: Set<String> = [try #require(store.tab(surface: c), "setup: the store has no tab c").id]
        store.holdTabs(held)
        let close = try #require(store.intendClose([c]), "setup: the close found no tab c")
        try #require(try Self.commandIndex("N", to: 3, in: store) == 4, "setup: the command's index is not 4")
        try Self.move("N", to: 3, in: store)
        try #require(try Self.order(store) == "tabNd", "setup: the move did not put N between b and d")

        // As `HiddenTabClose.restore` ends a hold.
        store.releaseHeldTabs(held)
        store.rejectIntent(close)
        #expect(try Self.order(store) == "tabcNd")
    }

    /// A LIMIT, not the daemon's order. Pane `t a b c N M`. `N` moves right after `b` (`t a b N c M`), then `M` moves
    /// right after `N` (`t a b N M c`; its command has the index 4). The daemon refuses the move of `N`. Its list is
    /// then `t a b c N M`, and its move of `M` to index 4 gives `t a b c M N`. The store shows `t a b c N M` until the
    /// move's event: `M` stays right after its neighbour `N`. By a read of the daemon, no act of a person reaches a
    /// refused move of a tab that stays in its pane: `move-tab` refuses an unknown pane or tab, and a drag into a
    /// pinned column that takes no tabs (`cmux-tui/crates/cmux-tui-core/src/server/cmd_tabs.rs`, `move-tab`;
    /// `cmux-tui/crates/cmux-layout-reducer/src/tab_moves.rs`, the same-pane move).
    @Test func aRefusedMoveOfTheNeighbourLeavesTheLaterMovedTabAfterIt() throws {
        let store = Self.store("tabcNM")
        let first = try Self.move("N", to: 3, in: store)
        try #require(try Self.commandIndex("M", to: 4, in: store) == 4, "setup: the command's index is not 4")
        try Self.move("M", to: 4, in: store)
        try #require(try Self.order(store) == "tabNMc", "setup: the two moves did not give t a b N M c")

        store.rejectIntent(first)
        #expect(try Self.order(store) == "tabcNM")
    }
}
