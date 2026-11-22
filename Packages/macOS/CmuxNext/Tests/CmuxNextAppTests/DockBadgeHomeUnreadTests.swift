@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The Dock badge counts Home's unread conversations next to the unread
/// workspace tabs (as Messages' Dock badge counts its unread messages), and a
/// conversation that a workspace tab shows with its own unread marker counts once.
@MainActor
struct DockBadgeHomeUnreadTests {
    /// One workspace: a conversation tab for `conv_tab` (unread or not) and a terminal tab (unread or not).
    static func store(conversationTabUnread: Bool, terminalUnread: Bool) throws -> DaemonStore {
        func note(_ on: Bool) -> String { on ? #"{"level":"info","notification":1,"unread":true}"# : "null" }
        let conversation = #"{"surface":1,"kind":"conversation","browser_renderer":"frontend","conversation":{"conversation":"conv_tab","owner":"local"},"title":"","notification":\#(note(conversationTabUnread))}"#
        let terminal = #"{"surface":2,"kind":"pty","tab_resource_id":"tab_b","terminal_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"","notification":\#(note(terminalUnread))}"#
        let json = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01","name":"w","screens":[{"id":4,"layout":{"type":"leaf","pane":3},"panes":[{"id":3,"active_tab":0,"tabs":[\#(conversation),\#(terminal)]}]}]}]}"#
        let store = DaemonStore()
        store.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8)))
        return store
    }

    @Test func homeUnreadConversationsAddToTheBadge() throws {
        let store = try Self.store(conversationTabUnread: false, terminalUnread: true)
        #expect(NotificationCenterService.unreadCount(store, homeUnread: []) == 1)
        #expect(NotificationCenterService.unreadCount(store, homeUnread: ["conv_a", "conv_b"]) == 3)
        #expect(NotificationCenterService.unreadCount(nil, homeUnread: ["conv_a"]) == 1)
    }

    @Test func aConversationShownAsAnUnreadTabCountsOnce() throws {
        let store = try Self.store(conversationTabUnread: true, terminalUnread: false)
        #expect(NotificationCenterService.unreadCount(store, homeUnread: ["conv_tab"]) == 1)
        #expect(NotificationCenterService.unreadCount(store, homeUnread: ["conv_tab", "conv_a"]) == 2)
        // A read tab of the conversation does not hide its Home unread.
        let read = try Self.store(conversationTabUnread: false, terminalUnread: false)
        #expect(NotificationCenterService.unreadCount(read, homeUnread: ["conv_tab"]) == 1)
    }
}
