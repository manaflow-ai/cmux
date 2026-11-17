@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// A new tab's move that is made while a close of a tab left of it is not settled: the new tab stays right after the
/// tab it follows when that close goes on, when its tab comes back, and when the daemon refuses it.
///
/// Decision of 2026-11-16: a new tab that shows one slot left of its place is an order fault that a person can see,
/// not a rare frame of a sample test. `NewTabCloseInterleaveOrderTests` samples the strip against a real daemon, so it
/// sees that order only when a sample falls in it (`the strip reordered: ["abNc", "bNc", "Nbc", "bNc"]`). This suite
/// makes the same steps at the store in one turn of the main actor: no daemon, no window, no wait, no sample loop.
///
/// The steps, as the app makes them. A person's close of a terminal first hides the tab with a close intent that is
/// not sent (`HiddenTabClose.hide`, from `TabCloseGuard.close`) while the daemon reads what runs there. The new tab's
/// move (`NewTabSlot`, then `TabMoves.move`) keeps its slot among the visible tabs as the index of its intent. Then
/// one of three things ends the close:
/// - the read finds no program: the hide lifts (`HiddenTabClose.lift`) and the close's own intent takes the tab out
///   again in the same turn (`CloseUndoToasts.close`, then `PaneController.prepareClose`);
/// - the read finds a program: the hide is rolled back (`HiddenTabClose.restore`) and the tab comes back;
/// - a close that was sent is refused by the daemon (`DaemonStore.rejectIntent`) and the tab comes back.
/// After each, the pane maps its strip from the store's list.
///
/// Limits: the move's intent is made here by hand, with the slot of `NewTabSlot.slot(for:in:)` and in the form of
/// `TabMoves.move`; the test sends no command and has no strip. The store is a second copy of the one pane of
/// `DaemonMoveIndexTests`.
@MainActor
struct AMoveMadeWhileACloseIsHiddenKeepsItsSlotTests {
    /// Which comes first: the new tab's move (the hide then finds the new tab in its slot), or the hide of the closed
    /// tab (the move is then made among the visible tabs).
    enum First: String, CaseIterable, Sendable { case move, hide }

    private static let pane = CmuxNextDaemon.PaneID(rawValue: 3)
    /// `t a b c N`: the pane's first terminal, three tabs, and the new tab last (the daemon appends it).
    private static let surfaces = (4...8).map { SurfaceID(rawValue: $0) }
    private static let letters = ["t", "a", "b", "c", "N"]

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: CmuxNextDaemon.ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: surfaces.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return store
    }

    /// The pane's tabs as letters, in the store's order.
    private static func order(_ pane: PaneModel) -> String {
        pane.tabs.map { tab in surfaces.firstIndex(of: tab.surface).map { letters[$0] } ?? "?" }.joined()
    }

    /// The one pane `t a b c N` in a store, the close of `a`, the new tab's move right after `b`, and each order the
    /// pane had (the first record is the pane at the start; the last is the list that the pane maps its strip from).
    @MainActor
    private final class Scene {
        private typealias Rows = AMoveMadeWhileACloseIsHiddenKeepsItsSlotTests

        let store: DaemonStore
        let pane: PaneModel
        let closed: SurfaceID
        let anchor: TabModel
        let new: TabModel
        private(set) var seen: [String]

        init() throws {
            let store = Rows.store()
            let pane = try #require(store.pane(Rows.pane), "setup: the store has no pane")
            let anchor = try #require(store.tab(surface: Rows.surfaces[2]), "setup: the store has no tab b")
            let new = try #require(store.tab(surface: Rows.surfaces[4]), "setup: the store has no new tab")
            self.store = store
            self.pane = pane
            self.closed = Rows.surfaces[1]
            self.anchor = anchor
            self.new = new
            self.seen = [Rows.order(pane)]
        }

        var order: String { Rows.order(pane) }
        var list: String { seen.joined(separator: ", ") }

        /// Records the pane's order after a step.
        func note() { seen.append(order) }

        /// The new tab's move right after b: the slot among the pane's visible tabs but the new one, kept as the
        /// index of the intent.
        func move() throws {
            let new = self.new, now = order
            let others = pane.tabs.filter { $0 !== new }
            let found = NewTabSlot.slot(for: .after(anchor), in: others)
            let slot = try #require(found, "setup: no slot after b in \(now)")
            store.intend(.moveTab(surface: new.surface, toPane: pane.handle, index: slot), transaction: .generate())
            note()
        }

        /// A person's close of `a` while the daemon's read decides: hidden, nothing sent.
        func hide() throws -> HiddenTabClose {
            let made = HiddenTabClose.hide([closed], in: store, panes: [])
            let hidden = try #require(made, "setup: the hide found no tab a")
            note()
            return hidden
        }
    }

    @Test(arguments: First.allCases)
    func theNewTabStaysAfterItsAnchorWhenTheHiddenCloseGoesOn(first: First) throws {
        let scene = try Scene()
        if first == .move { try scene.move() }
        let hidden = try scene.hide()
        if first == .hide { try scene.move() }
        try #require(scene.order == "tbNc", "setup: before the close goes on the pane is not t b N c: \(scene.list)")

        // The read ended with no program: the hide lifts and the close's own intent takes the tab out, in one turn.
        hidden.lift()
        scene.note()
        try #require(scene.store.intendClose([scene.closed]) != nil, "setup: the close found no tab a: \(scene.list)")
        scene.note()

        #expect(scene.order == "tbNc", "the new tab left its slot: \(scene.list)")
    }

    @Test
    func theNewTabStaysAfterItsAnchorWhenTheHiddenTabComesBack() throws {
        let scene = try Scene()
        let hidden = try scene.hide()
        try scene.move()
        try #require(scene.order == "tbNc", "setup: before the tab comes back the pane is not t b N c: \(scene.list)")

        // The read found a program: the hide is rolled back and the tab comes back at its place.
        hidden.restore()
        scene.note()

        #expect(scene.order == "tabNc", "the new tab left its slot: \(scene.list)")
    }

    /// Not the end state. The row sends no command and has no daemon. In the app the close of `a` was sent, so the
    /// move's command did not count `a`: it has the index 2, of the list `t b c N`. The daemon refuses the close and
    /// then runs the move on its own list `t a b c N`, which gives `t a N b c`. So the person sees this row's order
    /// `t a b N c` from the refusal to the move's event, and then `t a N b c`. The mend of that end state is the
    /// command's index, not the store's place.
    @Test
    func theNewTabStaysAfterItsAnchorWhenTheDaemonRefusesTheClose() throws {
        let scene = try Scene()
        // A close that is sent at once (no read, no hide): the store's close intent alone.
        let close = try #require(scene.store.intendClose([scene.closed]), "setup: the close found no tab a")
        scene.note()
        try scene.move()
        try #require(scene.order == "tbNc", "setup: before the refusal the pane is not t b N c: \(scene.list)")

        // The daemon kept the tab: the close's intent leaves the log and the tab shows again.
        scene.store.rejectIntent(close)
        scene.note()

        #expect(scene.order == "tabNc", "the new tab left its slot: \(scene.list)")
    }
}
