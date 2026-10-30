import AppKit
import Testing
@testable import MessagesLabSidebar

/// PINNED UNREAD DOT (user 2026-10-21, two screenshots: "unreads need to look like this instead.
/// for the pinned ones. make sure they dont intersect."). Messages' pinned tile shows unread as a
/// blue dot inline before the name under the avatar ("• Instinct"); the newest-message bubble
/// floats over the avatar's top. The old dot sat at the avatar's upper left, where the bubble's
/// tail points, and the two overlapped. These tests lay out real tiles at every grid width, with
/// short and long names and previews, 1:1 and group tiles, and check that the dot touches nothing.
@MainActor
@Suite(.serialized)
struct PinnedUnreadDotLayoutTests {
    private static let names = ["Al", "Instinct", "Chief", "Maximilian-Alexander Featherstonehaugh", "Design Review Group Name Long"]
    private static let previews = ["ok", "Sent one to your phone-number thread, check it", String(repeating: "long preview text ", count: 8)]

    /// The list widths with names (the compact list below 180 pt has no names): 2 and 3 columns,
    /// the narrowest and widest tiles.
    private static let widths: [CGFloat] = [180, 200, 239, 260, 290, 320, 380, 480, 640]

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let view: CmuxSidebarView
        var entries: [CmuxSidebarEntry]
        var controller: SidebarController { view.controller }

        init(width: CGFloat, dark: Bool) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var list: [CmuxSidebarEntry] = []
            for (i, name) in PinnedUnreadDotLayoutTests.names.enumerated() {
                for (j, preview) in PinnedUnreadDotLayoutTests.previews.enumerated() {
                    let id = "c\(i)-\(j)"
                    let group = i == 4
                    let people: [CmuxSidebarEntry.Person] = group
                        ? (0..<3).map { .init(id: "p\(i)-\($0)", name: "Person \($0)", initials: "P\($0)") }
                        : [.init(id: "p\(i)", name: name, initials: String(name.prefix(2)).uppercased())]
                    list.append(CmuxSidebarEntry(id: id, title: name, people: people, preview: preview, previewSender: group ? "Person 0" : nil,
                                                 lastAt: now.addingTimeInterval(-Double(list.count) * 60), unreadCount: 1, pinned: true))
                }
            }
            entries = list
            window.contentView = view
            show()
            view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.document.layoutSubtreeIfNeeded()
            controller.tile(force: true)
        }

        func show() { view.show(entries, pinned: entries.map(\.id)) }

        func tile(_ id: String) -> SidebarRowLayer? { controller.tileLayers.first { $0.conversationID == id } }
    }

    private func check(_ l: SidebarRowLayer, _ context: String) {
        let dot = l.dot.frame, avatar = l.avatar.frame, name = l.content.frame
        #expect(!l.dot.isHidden, "\(context): an unread tile shows its dot")
        #expect(l.bounds.contains(dot), "\(context): dot \(dot) inside tile \(l.bounds)")
        #expect(l.bounds.contains(name), "\(context): name \(name) inside tile \(l.bounds)")
        #expect(!dot.intersects(avatar), "\(context): dot \(dot) clear of avatar \(avatar)")
        #expect(!dot.intersects(name), "\(context): dot \(dot) clear of name \(name)")
        // Inline before the name: left of it, centered on its line.
        #expect(dot.maxX <= name.minX, "\(context): dot \(dot) before name \(name)")
        #expect(abs(dot.midY - (name.minY + 7)) <= 1.5, "\(context): dot \(dot) on the name's line \(name)")
        if !l.time.isHidden {
            // The bubble bitmap with its tail (1 pt left, 5 pt below the bubble).
            #expect(!dot.intersects(l.time.frame), "\(context): dot \(dot) clear of bubble+tail \(l.time.frame)")
            #expect(!name.intersects(l.time.frame), "\(context): name \(name) clear of bubble+tail \(l.time.frame)")
        }
        for s in l.senders { #expect(!dot.intersects(s.frame), "\(context): dot \(dot) clear of sender \(s.frame)") }
    }

    @Test(arguments: [false, true])
    func unreadDotSitsBeforeTheNameAndTouchesNothing(dark: Bool) throws {
        for w in Self.widths {
            let f = Fixture(width: w, dark: dark)
            #expect(!f.controller.metrics.compact)
            for e in f.entries {
                let l = try #require(f.tile(e.id), "width \(w): tile \(e.id)")
                check(l, "width \(w) dark \(dark) \(e.id) \"\(e.title)\"")
            }
        }
    }

    /// The dot is the list's unread colour (the host's notification blue), in light and dark.
    @Test(arguments: [false, true])
    func dotIsTheUnreadColor(dark: Bool) throws {
        let f = Fixture(width: 320, dark: dark)
        f.view.unreadColor = .systemBlue
        f.controller.tile(force: true)
        let l = try #require(f.tile("c1-1"))
        let expected = f.controller.palette.unread
        #expect(l.dot.backgroundColor == expected)
    }

    /// Mark as Read hides the dot and the name re-centres; Mark as Unread brings both back.
    @Test
    func markReadAndUnreadToggleTheDot() throws {
        let f = Fixture(width: 320, dark: false)
        let i = try #require(f.entries.firstIndex { $0.id == "c1-1" })
        f.entries[i].unreadCount = 0
        f.show(); f.controller.tile(force: true)
        var l = try #require(f.tile("c1-1"))
        #expect(l.dot.isHidden)
        #expect(abs(l.content.frame.midX - l.bounds.midX) <= 1, "a read tile's name is centred")
        f.entries[i].unreadCount = 1
        f.show(); f.controller.tile(force: true)
        l = try #require(f.tile("c1-1"))
        check(l, "re-marked unread")
    }
}
