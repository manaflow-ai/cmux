import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The Home conversation list draws no system blue (the user, 2026-10-18: "dont use blue here"):
/// a selected pinned tile or row takes the theme's translucent selection tint in every window
/// state (Leo 2026-10-19: not an opaque grey slab), and in the compact list the selection is a
/// disc behind the avatar.
@MainActor
struct HomeSidebarNeutralSelectionTests {
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func theSelectionIsTheThemeTintNotBlueOrGrey(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        home.appearance = appearance
        let controller = home.list.controller
        controller.appearanceChanged()
        var blue: CGColor?, grey: CGColor?, label: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            blue = NSColor.selectedContentBackgroundColor.cgColor
            grey = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            label = NSColor.labelColor.cgColor
        }
        let p = controller.palette
        #expect(!Self.same(p.selectionActive, blue), "the key-window selection is the system blue")
        #expect(!Self.same(p.selectionActive, grey), "the selection is still the opaque grey slab")
        #expect(p.selectionActive.alpha < 0.5, "the selection is not a translucent tint")
        #expect(Self.same(p.selectedText, label), "the selected text is not the label colour")
        // Home focused or not (the window not key): the same tint, never blue.
        controller.setWindowActive(false)
        #expect(!Self.same(controller.palette.selectionInactive, blue))
        #expect(Self.same(controller.palette.selectionActive, controller.palette.selectionInactive))
    }

    /// The compact list (avatars only) selects with a disc behind the avatar, not a row-wide slab.
    @Test func theCompactSelectionIsADiscBehindTheAvatar() throws {
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
        let disc = tile.selection.frame
        #expect(abs(disc.width - disc.height) < 0.5, "the compact tile's selection is not round")
        #expect(abs(tile.selection.cornerRadius - disc.width / 2) < 0.5)
        #expect(disc.contains(CGPoint(x: tile.avatar.frame.midX, y: tile.avatar.frame.midY)), "the disc is not behind the avatar")
        #expect(disc.width < tile.bounds.width, "the disc is the row-wide slab")
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
