@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// A new tab's move that is made while a person's close of a tab left of it is only hidden: the new tab stays right
/// after the tab it follows when the close goes on.
///
/// Decision of 2026-11-16: a new tab that shows one slot left of its place is an order fault that a person can see,
/// not a rare frame of a sample test. `NewTabCloseInterleaveOrderTests` samples the strip against a real daemon, so it
/// sees that order only when a sample falls in it (`the strip reordered: ["abNc", "bNc", "Nbc", "bNc"]`). This suite
/// makes the same steps at the store in one turn of the main actor: no daemon, no window, no wait, no sample loop.
///
/// The steps, as the app makes them. A person's close of a terminal first hides the tab with a close intent that is
/// not sent (`HiddenTabClose.hide`, from `TabCloseGuard.close`) while the daemon reads what runs there. The new tab's
/// move (`NewTabSlot`, then `TabMoves.move`) keeps its slot among the visible tabs as the index of its intent. When the
/// read ends with no program, the hide lifts (`HiddenTabClose.lift`) and the close's own intent takes the tab out
/// again in the same turn (`CloseUndoToasts.close`, then `PaneController.prepareClose`), and the pane maps its strip.
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

    @Test(arguments: First.allCases)
    func theNewTabStaysAfterItsAnchorWhenTheHiddenCloseGoesOn(first: First) throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.pane), "setup: the store has no pane")
        let closed = Self.surfaces[1]
        let anchor = try #require(store.tab(surface: Self.surfaces[2]), "setup: the store has no tab b")
        let new = try #require(store.tab(surface: Self.surfaces[4]), "setup: the store has no new tab")
        var seen = [Self.order(pane)]

        // The new tab's move right after b: the slot among the pane's visible tabs but the new one, kept as the
        // index of the intent.
        func move() throws {
            let slot = try #require(NewTabSlot.slot(for: .after(anchor), in: pane.tabs.filter { $0 !== new }),
                                    "setup: no slot after b in \(Self.order(pane))")
            store.intend(.moveTab(surface: new.surface, toPane: pane.handle, index: slot), transaction: .generate())
            seen.append(Self.order(pane))
        }

        if first == .move { try move() }
        let hidden = try #require(HiddenTabClose.hide([closed], in: store, panes: []), "setup: the hide found no tab a")
        seen.append(Self.order(pane))
        if first == .hide { try move() }
        try #require(Self.order(pane) == "tbNc", "setup: before the close goes on the pane is not t b N c: \(seen)")

        // The read ended with no program: the hide lifts and the close's own intent takes the tab out, in one turn.
        hidden.lift()
        seen.append(Self.order(pane))
        try #require(store.intendClose([closed]) != nil, "setup: the close found no tab a: \(seen)")
        seen.append(Self.order(pane))

        // The first record is the pane at the start; the last is the list that the pane maps its strip from.
        #expect(Self.order(pane) == "tbNc", "the new tab left its slot: \(seen.joined(separator: ", "))")
    }
}
