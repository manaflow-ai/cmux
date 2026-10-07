import AppKit
import Testing
@testable import MessagesLabSidebar

/// A host that keeps pins the way cmux does: the list asks, the host changes
/// its data and reloads.
@MainActor
final class PinningHost: SidebarDataSource, SidebarDelegate {
    var items: [ConversationSummary]
    var pinned: [String] = []
    weak var controller: SidebarController?

    init(count: Int) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        items = (0..<count).map { i in
            ConversationSummary(id: "c\(i)", title: "Person \(i)", participants: [], avatar: .monogram("P"), preview: "hi",
                                previewSender: nil, lastAt: now.addingTimeInterval(Double(-i * 60)), unreadCount: i == 2 ? 3 : 0,
                                pinned: false, muted: false, typing: false, lastReaction: nil, version: i)
        }
    }

    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot {
        ConversationListSnapshot(items: items.map { var s = $0; s.pinned = pinned.contains($0.id); return s }, pinned: pinned)
    }
    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) {}
    func sidebar(_ sidebar: SidebarController, setPinned on: Bool, for id: ConversationID) {
        if on { pinned.append(id) } else { pinned.removeAll { $0 == id } }
        sidebar.reloadData()
    }
}

/// MessagesLab v1.1 fixed a trap in SidebarController.updateHover(): unpinning the
/// last pinned tile while the pointer rested on it read a tile index that no longer
/// existed (Index out of range). cmux-next crashed the same way from the context menu.
@MainActor @Suite(.serialized) struct SidebarHoverTests {
    @Test func unpinningTheHoveredLastTileDoesNotTrap() {
        let host = PinningHost(count: 6)
        let sidebar = SidebarController()
        sidebar.dataSource = host
        sidebar.delegate = host
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.reloadData()
        sidebar.setPinned(true, "c1")
        #expect(sidebar.pinnedItems.count == 1)
        sidebar.mouseMoved(sidebar.tileRect(sidebar.pinnedItems.count - 1).insetBy(dx: 10, dy: 10).origin)
        sidebar.setPinned(false, "c1")
        #expect(sidebar.pinnedItems.isEmpty)
        sidebar.mouseMoved(nil)
    }
}
