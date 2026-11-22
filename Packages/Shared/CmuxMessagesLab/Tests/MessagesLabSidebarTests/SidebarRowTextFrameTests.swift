import AppKit
import Testing
@testable import MessagesLabSidebar

/// A row's name and preview never draw over its avatar: after the list
/// reconfigures a row whose bitmap did not change (the row above a new
/// selection, an unread row, a row with or without a preview), its text layer
/// keeps the text column's frame.
@MainActor @Suite(.serialized) struct SidebarRowTextFrameTests {
    final class Host: SidebarDataSource, SidebarDelegate {
        var items: [ConversationSummary]
        init() {
            let now = Date(timeIntervalSince1970: 1_790_000_000)
            items = (0..<8).map { i in
                ConversationSummary(id: "c\(i)", title: "Person \(i)", participants: [], avatar: .monogram("P"),
                                    preview: i % 2 == 0 ? "how are you doing" : "", previewSender: nil,
                                    lastAt: now.addingTimeInterval(Double(-i * 60)), unreadCount: i < 3 ? 2 : 0,
                                    pinned: false, muted: false, typing: false, lastReaction: nil, version: i)
            }
        }
        func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot {
            ConversationListSnapshot(items: items, pinned: [])
        }
        func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) {}
    }

    /// Visible row layers whose text overlaps their avatar.
    private func overlapping(_ sidebar: SidebarController) -> [CGRect] {
        (sidebar.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
            .filter { !$0.isHidden && !$0.content.isHidden && $0.content.contents != nil }
            .filter { $0.content.frame.intersects($0.avatar.frame) }
            .map(\.content.frame)
    }

    @Test(arguments: ["c0", "c1", "c2", "c3", "c4"])
    func textStaysRightOfTheAvatarAfterASelection(select id: String) {
        let host = Host()
        let sidebar = SidebarController()
        sidebar.dataSource = host
        sidebar.delegate = host
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        sidebar.reloadData()
        #expect(overlapping(sidebar).isEmpty)
        sidebar.select(id, notify: false, reveal: false)
        sidebar.select("c6", notify: false, reveal: false)
        sidebar.select(id, notify: false, reveal: false)
        #expect(overlapping(sidebar).isEmpty)
        sidebar.reloadData()
        #expect(overlapping(sidebar).isEmpty)
    }
}
