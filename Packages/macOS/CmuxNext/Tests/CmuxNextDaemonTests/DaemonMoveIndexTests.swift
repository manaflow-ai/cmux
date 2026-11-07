import Foundation
import Testing
@testable import CmuxNextDaemon

/// `DaemonStore.daemonMoveIndex(_:moving:in:)` through the store: its rule is cmux-layout-reducer's `daemon_move_index`
/// (over the app FFI; every case is a golden vector in `cmux-tui/crates/cmux-layout-reducer/tests/data/
/// optimistic_vectors.json`, run through the C ABI by the crate's FFI tests). This case keeps the store's half: the
/// held closes it reads from its intent log.
@MainActor
struct DaemonMoveIndexTests {
    /// A move in a pane while held closes keep tabs out of its visible order goes to the same place in the daemon's
    /// order (Leo 2026-11-05, the close/create shuffle), through the store's own entry point.
    @Test func aHeldCloseLeftOfTheSlotCounts() throws {
        let paneID = PaneID(rawValue: 3)
        let surfaces = (4...8).map { SurfaceID(rawValue: $0) }
        let store = DaemonStore()
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: paneID, layout: .leaf(paneID),
                                     panes: [PaneSnapshot(id: paneID, tabs: surfaces.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let pane = try #require(store.pane(paneID))
        store.holdTabs([try #require(store.tab(surface: surfaces[1])).id])
        #expect(store.intendClose([surfaces[1]]) != nil)
        let moved = store.daemonMoveIndex(2, moving: surfaces[4], in: pane)
        #expect(moved.final == 3)
        #expect(moved.current == 4)
    }
}
