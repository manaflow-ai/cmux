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

    /// THIS ROW PINS A LIMIT, NOT A WANTED RESULT. The wanted result is the daemon's order, `t a b c M N`: a mend of
    /// the limit changes this row's expect to it.
    ///
    /// Pane `t a b c N M`. `N` moves right after `b` (`t a b N c M`), then `M` moves right after `N` (`t a b N M c`;
    /// its command has the index 4). The move of `N` is refused. The daemon's list is then `t a b c N M`, and its
    /// move of `M` to index 4 gives `t a b c M N`. The store shows `t a b c N M`: `M` stays right after its neighbour
    /// `N`. The store's order heals when the answer of `M`'s move settles, not at the move's event: until then the
    /// store applies the waiting move again after each event (`IntentOverlay.restore`). Before this rule the store
    /// applied `M` again with its own index 4 and showed the daemon's order at once: in this case the rule is one
    /// swap of the 2 last tabs worse, for the time of one answer.
    ///
    /// Who reaches it:
    /// - The daemon gives no error to a move of a tab that stays in its pane. `move-tab` gives an error for an
    ///   unknown pane or tab (`cmux-tui/crates/cmux-tui-core/src/server/cmd_tabs.rs`), and so does the same-pane
    ///   move of the reducer (`cmux-tui/crates/cmux-layout-reducer/src/tab_moves.rs`). A pinned column does not make
    ///   a move that breaks it (`cmux-tui/crates/cmux-tui-core/src/mux/pinned_columns.rs`,
    ///   `ensure_pinned_columns_kept`): a tab that comes in while the column takes none, its first tab that leaves,
    ///   and its first tab that moves from the first place inside its pane. The daemon's answer is then
    ///   `moved: false`, not an error. The app refuses its move for that answer only when the tab goes to another
    ///   pane (`TabMoves.swift`, the send of `move-tab`); for a tab that stays in its pane the store's move settles
    ///   and is not refused, so that answer does not make this row's case.
    /// - The app's store refuses a move for each error of its request (`DaemonService+Intents.swift`, the `catch` of
    ///   the send): a request that passed its deadline and a lost connection too. After a missed deadline the
    ///   daemon can make the move later; then this rule and the older one each show a wrong order until the
    ///   events come.
    /// - 2 moves that wait in one pane need 2 drags of a person, or a drag and a command, inside one round trip to
    ///   the daemon. 2 new tabs do not make them: the second one's move waits for the answer of the first.
    @Test func aRefusedMoveOfTheNeighbourLeavesTheLaterMovedTabAfterIt() throws {
        let store = Self.store("tabcNM")
        let first = try Self.move("N", to: 3, in: store)
        try #require(try Self.commandIndex("M", to: 4, in: store) == 4, "setup: the command's index is not 4")
        try Self.move("M", to: 4, in: store)
        try #require(try Self.order(store) == "tabNMc", "setup: the two moves did not give t a b N M c")

        store.rejectIntent(first)
        #expect(try Self.order(store) == "tabcNM")
    }

    /// EXPECTED RED UNTIL THE LIMIT ABOVE IS MENDED: the same wrong order by a way with no refusal.
    ///
    /// Pane `t a b`; `t` is the first tab of a pinned column that takes tabs. `t` moves to the end (`a b t`), then
    /// `a` moves to the end, right after `t` (`b t a`; its command has the index 2). The daemon does not move `t`
    /// (the pinned column keeps its first tab at the first place) and answers `moved: false`, not an error, with no
    /// event. The app refuses its move for that answer only when the tab goes to another pane, so the move of `t`
    /// settles (`DaemonStore.noteSettled`) and leaves the log. The daemon's list is `t a b`, and its move of `a` to
    /// index 2 gives `t b a`: the wanted order, which the store showed at once before the rule of this type. With
    /// the rule the store shows `t a b` (`a` directly after `t`) until the answer of `a`'s move settles.
    ///
    /// Who reaches it, by a read of 2026-11-17: a person who drags the column's first tab inside its strip, or moves
    /// it with Move Tab Right, and moves a second tab to the place right of it before the first answer comes.
    ///
    /// Limits: the row sends no command, as each row here. It does not prove the daemon's answer: that is the
    /// daemon's row `pinned_column_refuses_moves_in_and_the_pinned_tab_moving_out_or_back`.
    @Test func aNeighboursMoveThatSettlesNotMadeLeavesTheLaterMovedTabAtTheDaemonsPlace() throws {
        let store = Self.store("tab")
        let first = try Self.move("t", to: 2, in: store)
        try #require(try Self.commandIndex("a", to: 2, in: store) == 2, "setup: the command's index is not 2")
        try Self.move("a", to: 2, in: store)
        try #require(try Self.order(store) == "bta", "setup: the two moves did not give b t a")

        store.noteSettled(first, at: store.appliedSequence)
        try #require(store.pendingIntents.count == 1, "setup: the move of t did not leave the log")
        #expect(try Self.order(store) == "tba")
    }
}
