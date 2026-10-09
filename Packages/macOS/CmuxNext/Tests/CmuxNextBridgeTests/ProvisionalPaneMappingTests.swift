import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing
@testable import CmuxNextBridge

/// S3 (plans/cmux-next/remote-state-ownership.md): the pane Cmd+D shows at once and the daemon's
/// pane that confirms it are the same layout pane (the same `LayoutPaneID`, keyed by the
/// client-minted public pane id), so the pane's view is kept across the swap; only the daemon
/// handle behind it changes. Its tab keeps its id (the client-minted tab id) too.
@MainActor @Suite struct ProvisionalPaneMappingTests {
    private func tree() throws -> DaemonTree {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(BridgeFixture.Envelope.self, from: Data(contentsOf: url)).data
    }

    @Test func theProvisionalAndTheConfirmedPaneAreOneLayoutPane() throws {
        let tree = try tree()
        let store = DaemonStore()
        store.apply(snapshot: tree)
        let provisional = ProvisionalPane()
        store.intend(.splitPane(pane: 16, direction: .right, ratio: 0.5, provisional: provisional), transaction: "tx")
        let workspace = try #require(store.workspaces.first { $0.screens.contains { $0.handle == 17 } })
        let shown = LayoutMapping.shared.map(workspace)
        let id = LayoutPaneID(provisional.paneID)
        #expect(shown.handles.panes[id] == provisional.handle)
        let shownTab = try #require(store.pane(provisional.handle)?.tabs.first?.id)

        var confirmed = tree
        let w = try #require(confirmed.workspaces.firstIndex { $0.screens.contains { $0.id == 17 } })
        let s = try #require(confirmed.workspaces[w].screens.firstIndex { $0.id == 17 })
        confirmed.workspaces[w].screens[s].layout = .split(id: 90, direction: .right, ratio: 0.5, a: .leaf(16), b: .leaf(91))
        confirmed.workspaces[w].screens[s].panes.append(
            PaneSnapshot(id: 91, resourceID: ResourceID(rawValue: provisional.paneID),
                         tabs: [TabSnapshot(surface: 92, tabResourceID: ResourceID(rawValue: provisional.tabID))]))
        store.apply(snapshot: confirmed)
        let after = LayoutMapping.shared.map(workspace)
        #expect(after.handles.panes[id] == 91, "the same layout pane now names the daemon's pane")
        #expect(Set(after.handles.panes.keys) == Set(shown.handles.panes.keys))
        #expect(store.pane(91)?.tabs.first?.id == shownTab, "the tab keeps its id across the swap")
    }
}
