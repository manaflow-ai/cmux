import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The Home conversation list selects as Messages does (macOS 26; the user, 2026-11-23: "make sure
/// that the selected colour is blue for chats"): the system blue with white text in a key window,
/// whatever the theme's or the system's accent, the system's grey when the window is not key, and
/// in the compact list the selection is the row's, behind the avatar.
@MainActor
struct HomeSidebarNeutralSelectionTests {
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func theSelectionIsMessagesBlue(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        home.appearance = appearance
        home.applyColors()
        let controller = home.list.controller
        controller.appearanceChanged()
        var blue: CGColor?, grey: CGColor?, white: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            blue = NSColor.systemBlue.cgColor
            grey = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            white = NSColor.alternateSelectedControlTextColor.cgColor
        }
        #expect(!home.list.neutralSelection)
        let p = controller.palette
        #expect(Self.same(p.selectionActive, blue), "the key-window selection is not the system blue")
        #expect(Self.same(p.selectedText, white), "the selected text is not white")
        controller.setWindowActive(false)
        #expect(Self.same(controller.palette.selectionInactive, grey), "the inactive selection is not the system grey")
    }

    /// The compact list (avatars only) selects as a row does: the rounded selection across the row.
    @Test func theCompactSelectionIsTheRows() throws {
        let list = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
        list.neutralSelection = true
        let now = Date()
        list.show([
            CmuxSidebarEntry(id: "a", title: "Austin", people: [.init(id: "p1", name: "Austin", initials: "A")],
                             preview: "hi", previewSender: nil, lastAt: now, unreadCount: 0, pinned: true),
            CmuxSidebarEntry(id: "b", title: "Mia", people: [.init(id: "p2", name: "Mia", initials: "M")],
                             preview: "hey", previewSender: nil, lastAt: now, unreadCount: 1, pinned: false),
        ], pinned: ["a"])
        list.layoutSubtreeIfNeeded()
        list.select("a")
        let tile = try #require(list.controller.tileLayers.first { $0.conversationID == "a" })
        #expect(!tile.selection.isHidden)
        // Messages' narrow list: the row's rounded selection across the row, behind the avatar.
        let slab = tile.selection.frame
        #expect(slab == tile.bounds)
        #expect(tile.selection.cornerRadius == SidebarMetrics.selectionRadius)
        #expect(slab.contains(CGPoint(x: tile.avatar.frame.midX, y: tile.avatar.frame.midY)), "the selection is not behind the avatar")
    }

    /// Equal after conversion to sRGB (system colours resolve in different colour spaces).
    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let x = a?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              let y = b?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              x.count == y.count else { return false }
        return zip(x, y).allSatisfy { abs($0 - $1) < 0.002 }
    }
}
