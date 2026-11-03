@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// The page tab store closes the page tabs of a pane the store no longer lists, and keeps those of
/// a pane that is still there, asking the store about its own panes (perf-lead.md section 2 row 29 c).
@MainActor @Suite struct PageTabGonePaneTests {
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)]), PaneSnapshot(id: 2, tabs: [])]
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: panes)
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    @Test func aGonePanesPageTabsCloseAndALivePanesStay() throws {
        let store = Self.store()
        let kept = try #require(store.pane(1)?.id)
        let gone = try #require(store.pane(2)?.id)
        let pages = InternalPageTabStore()
        pages.open(.settings, in: kept, of: store)
        pages.open(.changelog, in: gone, of: store)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneClosed(PaneDelta(
            workspace: 1, screen: 1, pane: 2, index: nil, entity: PaneSnapshot(id: 2, tabs: []), clientTransactionID: nil)))])
        pages.closeGonePanes(in: store)
        #expect(pages.tabIDs(in: gone).isEmpty, "the gone pane's page tab stayed")
        #expect(pages.tabIDs(in: kept).count == 1, "the live pane's page tab closed")
    }
}
