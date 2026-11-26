import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The compact Home list draws a pinned conversation at the same size and on the same rhythm as
/// every other conversation (the user, 2026-10-19: "pinned should be same size imo"): one column of
/// the full rows with the avatar alone (Messages' narrow list, 2026-11-23). A line in a 10 pt gap parts the
/// pinned avatars from the rest (Messages' strip, the user's recording 2026-11-24), never a bigger avatar.
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
        let rowAvatar = c.metrics.rowAvatar(rowHeight: rowFrame.height).offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let pinAvatar = tile.avatar.frame.offsetBy(dx: tileFrame.minX, dy: tileFrame.minY)
        // Same diameter.
        #expect(pinAvatar.size == rowAvatar.size, "pinned \(pinAvatar.size) vs row \(rowAvatar.size)")
        // Same column.
        #expect(abs(pinAvatar.midX - rowAvatar.midX) < 0.5)
        // Messages' strip: the first row's avatar sits a row and the divider's 10 pt gap under the pinned one.
        let step = c.metrics.listRowHeight + c.metrics.compactDividerGapScaled
        #expect(abs((rowAvatar.midY - pinAvatar.midY) - step) < 0.5,
                "pinned-to-row step \(rowAvatar.midY - pinAvatar.midY), expected \(step)")
        // The divider marks the pinned group: 54 x 2 pt, centred across the list and in the gap.
        let divider = try #require(c.document.layer?.sublayers?.first { $0.frame.size == c.metrics.compactDividerSize && !$0.isHidden })
        #expect(abs(divider.frame.midX - rowAvatar.midX) < 0.5)
        #expect(abs(divider.frame.midY - (pinAvatar.midY + rowAvatar.midY) / 2) < 0.5)
        // The selection is the narrowest strip's slab at every strip width, centred on the avatar (a wider strip draws
        // no bar across it), and a row's slab is the same.
        list.select("a")
        let slab = tile.selection.frame.offsetBy(dx: tileFrame.minX, dy: tileFrame.minY)
        #expect(slab.width == c.metrics.compactSelectionWidth, "a \(slab.width) pt slab in a \(width) pt strip")
        #expect(abs(slab.midX - pinAvatar.midX) < 0.5)
        #expect(abs(c.selectionRect(0).width - slab.width) < 0.5 && abs(c.selectionRect(0).midX - slab.midX) < 0.5)
        #expect(abs(tileFrame.minX - SidebarMetrics.selectionInsetX) < 0.5)
        #expect(tile.selection.cornerRadius == c.metrics.compactSelectionRadius)
        // The unread dot sits where a row's dot sits, and no name shows.
        let dot = try #require(c.tileGeometry(0).dot)
        #expect(abs(dot.width - SidebarMetrics.dotDiameter) < 0.5)
        let row = try #require(c.rowLayers.values.first { $0.conversationID == "b" })
        #expect(!row.dot.isHidden)
        #expect(abs(dot.midX + tileFrame.minX - (row.dot.frame.midX + rowFrame.minX)) < 0.5, "tile coordinates vs row coordinates")
        #expect(abs(dot.midY - row.dot.frame.midY) < 0.5)
        #expect(tile.content.isHidden, "a name shows in the narrow list")
    }

    /// The full-width list keeps Messages' big pinned grid (only the rail changed).
    @Test func theWideGridKeepsItsBigTiles() {
        let list = rail(width: 320)
        #expect(list.controller.metrics.pinAvatar > SidebarMetrics.avatar)
    }

    /// A selected pinned tile is Messages' slab at every width: the avatar with 10 pt on the top and the sides, and
    /// its name inside, never the tile's whole width (the user, 2026-11-23: a wide list drew a wide slab; Messages
    /// keeps an 88 pt avatar in a 108 pt slab). A long name truncates inside the slab.
    @Test(arguments: [180, 220, 259, 260, 328, 400, 500, 640] as [CGFloat])
    func theSelectedTileHugsItsAvatar(_ width: CGFloat) throws {
        let list = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        let now = Date()
        let names = ["Christopher Montgomery-Alexander", "Lawrence", "Al"]
        let entries = names.enumerated().map { i, name in
            CmuxSidebarEntry(id: "t\(i)", title: name, people: [.init(id: "p\(i)", name: name, initials: String(name.prefix(2)))],
                             preview: "hi", previewSender: nil, lastAt: now, unreadCount: i == 1 ? 1 : 0, pinned: true)
        }
        list.show(entries, pinned: entries.map(\.id))
        list.layoutSubtreeIfNeeded()
        let c = list.controller
        #expect(!c.metrics.compact)
        for id in entries.map(\.id) {
            list.select(id)
            let tile = try #require(c.tileLayers.first { $0.conversationID == id })
            let slab = tile.selection.frame, avatar = tile.avatar.frame
            #expect(!tile.selection.isHidden)
            #expect(slab.width == min(tile.bounds.width - 4, avatar.width + 2 * SidebarMetrics.pinSelectionPad), "\(id) at \(width)")
            #expect(abs(slab.midX - avatar.midX) <= 0.5, "\(id) at \(width): the slab is off the avatar")
            #expect(avatar.minY - slab.minY == SidebarMetrics.pinSelectionPad)
            #expect(tile.bounds.insetBy(dx: 1, dy: 1).contains(slab), "\(id) at \(width): the slab leaves the tile")
            #expect(slab.contains(tile.content.frame), "\(id) at \(width): the name \(tile.content.frame) leaves the slab \(slab)")
            if !tile.dot.isHidden { #expect(slab.contains(tile.dot.frame), "\(id) at \(width): the dot leaves the slab") }
        }
        #expect(c.metrics.pinAvatar <= SidebarMetrics.pinMaxAvatar)
    }
}
