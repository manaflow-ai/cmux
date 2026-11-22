@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The manual unread mark counts once in the Dock badge (as the old app's
/// manual unread did), and the tab lookup the typing path uses finds the
/// workspace showing a tab.
@MainActor
struct WorkspaceUnreadMarkTests {
    static func store(markedUnread: Bool, unreadTab: Bool) throws -> DaemonStore {
        let notification = unreadTab ? #"{"level":"info","notification":1,"unread":true}"# : "null"
        let tab = #"{"surface":1,"kind":"pty","tab_resource_id":"tab_a","terminal_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"","notification":\#(notification)}"#
        let json = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01","name":"w","marked_unread":\#(markedUnread),"screens":[{"id":4,"layout":{"type":"leaf","pane":3},"panes":[{"id":3,"active_tab":0,"tabs":[\#(tab)]}]}]},{"id":2,"key":"1b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c02","name":"other","screens":[]}]}"#
        let store = DaemonStore()
        store.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8)))
        return store
    }

    @Test func aMarkedWorkspaceCountsOnceInTheBadge() throws {
        #expect(NotificationCenterService.unreadCount(try Self.store(markedUnread: true, unreadTab: false)) == 1)
        #expect(NotificationCenterService.unreadCount(try Self.store(markedUnread: false, unreadTab: false)) == 0)
        // Unread tabs already count the workspace; the mark adds nothing.
        #expect(NotificationCenterService.unreadCount(try Self.store(markedUnread: true, unreadTab: true)) == 1)
    }

    @Test func findsTheWorkspaceShowingATab() throws {
        let store = try Self.store(markedUnread: true, unreadTab: false)
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(WorkspaceUnreadMark.workspace(ofTab: tab.id, in: store)?.name == "w")
        #expect(WorkspaceUnreadMark.workspace(ofTab: "missing", in: store) == nil)
    }
}
