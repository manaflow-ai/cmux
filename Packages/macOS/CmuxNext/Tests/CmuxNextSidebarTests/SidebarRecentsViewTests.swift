import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Recents draws one row per chat, newest first as the App hands them over,
/// and a press opens that chat.
@MainActor @Suite struct SidebarRecentsViewTests {
    @Test func rowsFollowTheChatsAndOpenOnPress() throws {
        let view = SidebarRecentsView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        view.update([SidebarRecentsView.Row(id: "a", title: "Fix CI", brand: nil),
                     SidebarRecentsView.Row(id: "b", title: SidebarRecentsView.newChatTitle, brand: nil)])
        view.layoutSubtreeIfNeeded()
        let rows = view.subviews.compactMap { $0 as? SidebarItemRowView }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(rows.map(\.info.title) == ["Fix CI", "New chat"])
        #expect(rows.map(\.frame.minY) == [0, Metrics.sidebarRowHeight])
        #expect(SidebarRecentsView.height(rows: 2) == Metrics.sidebarRowHeight * 2)
        try #require(rows.first).onPress?()
        #expect(opened == ["a"])
        // A chat that left takes its row with it; the one that stays keeps its view.
        let kept = rows[1]
        view.update([SidebarRecentsView.Row(id: "b", title: "New chat", brand: nil)])
        view.layoutSubtreeIfNeeded()
        #expect(view.subviews.compactMap { $0 as? SidebarItemRowView } == [kept])
        #expect(kept.frame.minY == 0)
    }
}
