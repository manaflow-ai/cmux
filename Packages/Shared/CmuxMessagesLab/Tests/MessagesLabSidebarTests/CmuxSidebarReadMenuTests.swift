import AppKit
import Testing
@testable import MessagesLabSidebar

/// cx-k9go: a Home conversation's context menu offers Mark as Read while it is unread and Mark as
/// Unread once it is read, each reaching the host (`onSetRead`).
@MainActor @Suite(.serialized) struct CmuxSidebarReadMenuTests {
    static func entry(_ id: String, unread: Int) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: id, title: id, people: [.init(id: "p_\(id)", name: id, initials: "A")], preview: "hi",
                         previewSender: nil, lastAt: Date(timeIntervalSince1970: 1_790_000_000), unreadCount: unread, pinned: false)
    }

    private func sidebar() -> CmuxSidebarView {
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        view.show([Self.entry("read", unread: 0), Self.entry("unread", unread: 2)], pinned: [])
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func menu(_ view: CmuxSidebarView, row: Int) throws -> NSMenu {
        let rect = view.controller.rowRect(row)
        return try #require(view.controller.menu(at: CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test func aReadConversationOffersMarkAsUnread() throws {
        let view = sidebar()
        var calls: [String] = []
        view.onSetRead = { read, id in calls.append("\(read ? "read" : "unread") \(id)") }
        let row = try #require(view.controller.rowItems.firstIndex { view.entries[$0].id == "read" })
        let menu = try menu(view, row: row)
        let index = try #require(menu.items.firstIndex { $0.title == SidebarStrings.markUnread })
        #expect(!menu.items.contains { $0.title == SidebarStrings.markRead })
        menu.performActionForItem(at: index)
        #expect(calls == ["unread read"])
    }

    @Test func anUnreadConversationOffersMarkAsRead() throws {
        let view = sidebar()
        var calls: [String] = []
        view.onSetRead = { read, id in calls.append("\(read ? "read" : "unread") \(id)") }
        let row = try #require(view.controller.rowItems.firstIndex { view.entries[$0].id == "unread" })
        let menu = try menu(view, row: row)
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == SidebarStrings.markRead }))
        #expect(calls == ["read unread"])
    }
}
