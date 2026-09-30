import Foundation
import Testing
@testable import CmuxNextDaemon

/// The workspace unread count follows tab markers: acknowledging a tab
/// (a `tab-changed` delta, no workspace delta) must drop the sidebar badge
/// and the Dock count, not keep the daemon's stale snapshot rollup.
@MainActor @Suite struct UnreadRollupTests {
    @Test func acknowledgingATabDropsTheWorkspaceUnreadCount() throws {
        let store = DaemonStore()
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        // notification-ack-v1 daemons serve the rollup with the workspace.
        tree.workspaces[0].unreadCount = 1
        store.apply(snapshot: tree)
        let workspace = try #require(store.workspaces.first)
        let tab = try #require(store.tab(surface: 3))
        #expect(tab.hasUnread)
        #expect(workspace.unreadCount == 1)
        let pane = try #require(store.pane(containing: 3))

        var read = tab.snapshot
        read.notification?.unread = false
        let delta = TabDelta(workspace: workspace.handle, screen: 5, pane: pane.handle, surface: 3, index: nil, entity: read)
        store.apply(.tabChanged(delta))
        #expect(!tab.hasUnread)
        #expect(workspace.unreadCount == 0)
    }
}
