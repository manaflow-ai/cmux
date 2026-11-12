import Observation
import Testing
@testable import CmuxNextDaemon

/// `DaemonStore.daemonMoveIndex(_:moving:in:)`: a move into a slot of the visible tabs, sent while a close of a tab
/// left of the slot is held back from the daemon (`HiddenTabClose`), goes to the same place in the daemon's order
/// (Leo 2026-11-05, the close/create shuffle: Cmd-T after b, close a, and the new tab ended first once a's close
/// went out). A close already sent reaches the daemon first and does not count.
@MainActor
struct DaemonMoveIndexTests {
    private static let pane = PaneID(rawValue: 3)
    // x a b c N
    private static let surfaces = (4...8).map { SurfaceID(rawValue: $0) }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: surfaces.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return store
    }

    @Test func noCloseInFlightKeepsTheIndex() throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.pane))
        let moved = store.daemonMoveIndex(3, moving: Self.surfaces[4], in: pane)
        #expect(moved.final == 3)
        #expect(moved.current == 4)
    }

    /// a's close is held: the visible tabs are x b c N; N after b is visible index 2, daemon index 3 (x a b N c).
    @Test func aHeldCloseLeftOfTheSlotCounts() throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.pane))
        store.holdTabs([try #require(store.tab(surface: Self.surfaces[1])).id])
        #expect(store.intendClose([Self.surfaces[1]]) != nil)
        #expect(pane.tabs.map(\.surface) == [Self.surfaces[0], Self.surfaces[2], Self.surfaces[3], Self.surfaces[4]])
        let moved = store.daemonMoveIndex(2, moving: Self.surfaces[4], in: pane)
        #expect(moved.final == 3)
        #expect(moved.current == 4)
    }

    /// a's close went out (not held): the daemon drops a before the move arrives, so the visible index stands.
    @Test func aSentCloseDoesNotCount() throws {
        let store = Self.store()
        #expect(store.intendClose([Self.surfaces[1]]) != nil)
        let pane = try #require(store.pane(Self.pane))
        let moved = store.daemonMoveIndex(2, moving: Self.surfaces[4], in: pane)
        #expect(moved.final == 2)
        #expect(moved.current == 3)
    }

    /// The end of the visible tabs is the end of the daemon's, held tabs and all.
    @Test func theEndStaysTheEnd() throws {
        let store = Self.store()
        let pane = try #require(store.pane(Self.pane))
        store.holdTabs([try #require(store.tab(surface: Self.surfaces[3])).id])
        #expect(store.intendClose([Self.surfaces[3]]) != nil)
        let moved = store.daemonMoveIndex(3, moving: Self.surfaces[1], in: pane)
        #expect(moved.final == 4)
        #expect(moved.current == 1)
    }

    /// A tab the person closed is closed lately (`closedLately`) once its close settles, so a new tab's move stops waiting
    /// for it to be listed (Leo 2026-11-05: "delete the proper thing"); a pending close does not count (it can still give
    /// the tab back), and a rejected one gives it back.
    @Test func aClosedTabIsClosedLatelyOnceItsCloseSettles() throws {
        let store = Self.store()
        let tab = try #require(store.tab(surface: Self.surfaces[1]))
        #expect(!store.closedLately(Self.surfaces[1]) && !store.closedLately(tab.id))
        let rejected = try #require(store.intendClose([Self.surfaces[1]]))
        #expect(!store.closedLately(Self.surfaces[1]) && !store.closedLately(tab.id), "pending: it can still come back")
        store.rejectIntent(rejected)
        #expect(store.tab(surface: Self.surfaces[1]) != nil, "the rejected close shows the tab again")
        #expect(!store.closedLately(Self.surfaces[1]) && !store.closedLately(tab.id), "a rejected close leaves the tab open")

        let close = try #require(store.intendClose([Self.surfaces[1]]))
        store.noteSettledAtNextSnapshot(close)
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                                     panes: [PaneSnapshot(id: Self.pane, tabs: Self.surfaces.filter { $0 != Self.surfaces[1] }.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [workspace]))
        #expect(store.pendingIntents.isEmpty, "the snapshot settled the close")
        #expect(store.closedLately(Self.surfaces[1]) && store.closedLately(tab.id))
        #expect(!store.closedLately(Self.surfaces[2]), "only the closed tab")
    }

    /// Review of #38105: the daemon's records drop the tab before the close's reply settles it (the overlay already hid it,
    /// so nothing a reader sees changes then). The settlement alone still tells a reader of `closedLately` (a new tab's
    /// move waiting for its tab) that it changed.
    @Test func aCloseSettledAfterItsRecordsTellsClosedLatelyReaders() throws {
        let store = Self.store()
        let close = try #require(store.intendClose([Self.surfaces[1]]))
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                                     panes: [PaneSnapshot(id: Self.pane, tabs: Self.surfaces.filter { $0 != Self.surfaces[1] }.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [workspace]))
        try #require(!store.pendingIntents.isEmpty, "the close is not settled by the records alone")
        #expect(!store.closedLately(Self.surfaces[1]))
        @MainActor final class Told { var told = false }
        let told = Told()
        withObservationTracking { _ = store.closedLately(Self.surfaces[1]) } onChange: { MainActor.assumeIsolated { told.told = true } }
        store.noteSettled(close, at: store.appliedSequence)
        #expect(store.pendingIntents.isEmpty, "the reply settled the close")
        #expect(told.told, "the settlement told the reader")
        #expect(store.closedLately(Self.surfaces[1]))
    }
}
