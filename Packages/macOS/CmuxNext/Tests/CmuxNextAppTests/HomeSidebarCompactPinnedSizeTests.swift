import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The compact Home list (the avatar rail) draws a pinned conversation at the same size and on
/// the same rhythm as every other conversation (the user, 2026-10-19: "pinned should be same size
/// imo"). Pinned shows as a hairline under the pinned group, never as a bigger avatar.
@MainActor
struct HomeSidebarCompactPinnedSizeTests {
    private func rail(width: CGFloat) -> CmuxSidebarView {
        let list = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        list.neutralSelection = true
        let now = Date()
        func entry(_ id: String, _ name: String, unread: Int, pinned: Bool) -> CmuxSidebarEntry {
            CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-" + id, name: name, initials: String(name.prefix(2)))],
                             preview: "hi", previewSender: nil, lastAt: now, unreadCount: unread, pinned: pinned)
        }
        list.show([
            entry("a", "CM", unread: 1, pinned: true),
            entry("b", "CM", unread: 1, pinned: false),
            entry("c", "AW", unread: 0, pinned: false),
        ], pinned: ["a"])
        list.layoutSubtreeIfNeeded()
        return list
    }

    @Test(arguments: [SidebarMetrics.minimumWidth, 100, 140])
    func pinnedAndUnpinnedAvatarsMatch(_ width: CGFloat) throws {
        let list = rail(width: width)
        let c = list.controller
        #expect(c.metrics.compact)
        let tile = try #require(c.tileLayers.first { $0.conversationID == "a" })
        let tileFrame = c.tileRect(0)
        let rowFrame = c.rowRect(0)
        let rowAvatar = CGRect(x: c.metrics.rowAvatarX, y: ((rowFrame.height - SidebarMetrics.avatar) / 2).rounded(),
                               width: SidebarMetrics.avatar, height: SidebarMetrics.avatar)
            .offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let pinAvatar = tile.avatar.frame.offsetBy(dx: tileFrame.minX, dy: tileFrame.minY)
        // Same diameter.
        #expect(pinAvatar.size == rowAvatar.size, "pinned \(pinAvatar.size) vs row \(rowAvatar.size)")
        // Same column.
        #expect(abs(pinAvatar.midX - rowAvatar.midX) < 0.5)
        // Even rhythm: the pinned avatar sits one row height above the first row's avatar.
        #expect(abs((rowAvatar.midY - pinAvatar.midY) - SidebarMetrics.rowHeight) < 0.5,
                "pinned-to-row step \(rowAvatar.midY - pinAvatar.midY), row step \(SidebarMetrics.rowHeight)")
        // The selection disc is the row's disc size too.
        list.select("a")
        let d = SidebarMetrics.avatar + 8
        #expect(abs(tile.selection.frame.width - d) < 0.5)
        // The unread dot sits where a row's dot sits.
        let dot = try #require(c.tileGeometry(0).dot)
        #expect(abs(dot.width - SidebarMetrics.dotDiameter) < 0.5)
        #expect(abs(dot.midX - c.metrics.dotCenterX) < 0.5)
        #expect(abs(dot.midY - tileFrame.height / 2) < 0.5)
        // Pinned stays visible: a hairline under the pinned group, no wider than the avatar.
        #expect(!tile.separator.isHidden, "nothing marks the pinned group")
        #expect(tile.separator.frame.width <= SidebarMetrics.avatar + 0.5)
    }

    /// The full-width list keeps Messages' big pinned grid (only the rail changed).
    @Test func theWideGridKeepsItsBigTiles() {
        let list = rail(width: 320)
        #expect(list.controller.metrics.pinAvatar > SidebarMetrics.avatar)
        #expect(list.controller.tileLayers.first?.separator.isHidden == true)
    }
}
