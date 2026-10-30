import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxTheme
@testable import MessagesLabSidebar
import Testing

/// The Home conversation list marks each unread conversation with a blue dot on the row's leading
/// edge, as Messages does (the user, 2026-10-21: "we need to add blue unread dots to home"). The
/// dot is the notification blue (`Palette.notificationBlue`, the unread rings' default) or the
/// user's `notifications.attention.color`, never the theme accent: the default theme's accent is a
/// neutral grey, so the dot drew grey and read as missing. It shows in the full list, on a pinned
/// tile and in the narrow avatar-only list, and hides once the conversation is read.
@MainActor
struct HomeSidebarUnreadDotTests {
    /// The app's default look: a theme with no accent of its own (the accent resolves to a grey).
    private static func neutralScope(dark: Bool) -> ThemeScope {
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xFFFFFF))
            : ThemeInput(background: ThemeRGB(hex: 0xF5F5F5), foreground: ThemeRGB(hex: 0x1E1E1E))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Neutral"), input: input, animated: false)
        return scope
    }

    private static func home(width: CGFloat, dark: Bool) -> HomeSidebarView {
        _ = NSApplication.shared
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        home.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        neutralScope(dark: dark).root(home)
        home.list.controller.appearanceChanged()
        home.applyColors()
        return home
    }

    private static func entry(_ id: String, _ name: String, unread: Int, pinned: Bool = false) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p-" + id, name: name, initials: String(name.prefix(1)))],
                         preview: "See you at the standup", previewSender: nil, lastAt: Date(), unreadCount: unread, pinned: pinned)
    }

    @Test(arguments: [true, false])
    func theDotIsNotificationBlueNotTheThemeAccent(dark: Bool) throws {
        let home = Self.home(width: 320, dark: dark)
        let dot = home.list.controller.palette.unread
        #expect(Self.same(dot, Palette.notificationBlue.cgColor),
                "the unread dot is \(String(describing: dot.components)), not the notification blue")
    }

    @Test func theDotTakesTheUsersAttentionColor() throws {
        let home = Self.home(width: 320, dark: true)
        let custom = NSColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1)
        home.unreadDotColor = custom
        #expect(Self.same(home.list.controller.palette.unread, custom.cgColor))
        home.unreadDotColor = nil
        #expect(Self.same(home.list.controller.palette.unread, Palette.notificationBlue.cgColor))
    }

    /// Unread rows and tiles show the dot and read ones do not, in the full list and the narrow
    /// avatar-only list; reading a conversation (unread 0 from the daemon) hides its dot.
    @Test(arguments: [320, 76] as [CGFloat])
    func unreadRowsAndTilesShowTheDot(width: CGFloat) throws {
        let home = Self.home(width: width, dark: true)
        let list = home.list
        list.show([Self.entry("a", "Austin", unread: 2, pinned: true), Self.entry("b", "Mia", unread: 0, pinned: true),
                   Self.entry("c", "Chief", unread: 3), Self.entry("d", "Pai", unread: 0)], pinned: ["a", "b"])
        list.layoutSubtreeIfNeeded()
        let c = list.controller
        #expect(c.indicators(.tile(0))?.dot == true, "an unread pinned tile has no dot")
        #expect(c.indicators(.tile(1))?.dot == false, "a read pinned tile shows a dot")
        #expect(c.indicators(.row(0))?.dot == true, "an unread row has no dot")
        #expect(c.indicators(.row(1))?.dot == false, "a read row shows a dot")

        // The daemon moved the read cursor: the dot goes.
        list.show([Self.entry("a", "Austin", unread: 2, pinned: true), Self.entry("b", "Mia", unread: 0, pinned: true),
                   Self.entry("c", "Chief", unread: 0), Self.entry("d", "Pai", unread: 0)], pinned: ["a", "b"])
        list.layoutSubtreeIfNeeded()
        #expect(c.indicators(.row(0))?.dot == false, "a read row keeps its dot")
    }

    /// Equal after conversion to sRGB.
    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let x = a?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              let y = b?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              x.count == y.count else { return false }
        return zip(x, y).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
