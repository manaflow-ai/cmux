import AppKit
import Testing
@testable import MessagesLabSidebar

/// cx-abv: the unread dot is the host's colour (cmux: the theme accent) in light and dark,
/// resolved in each appearance, never the system blue.
@MainActor @Suite struct SidebarColorTests {
    private static func rgb(_ c: CGColor) -> [CGFloat] {
        (NSColor(cgColor: c)?.usingColorSpace(.sRGB)).map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map { ($0 * 255).rounded() } } ?? []
    }

    @Test func theUnreadDotTakesTheHostsColourInLightAndDark() {
        let accent = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
                : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        }
        let light = SidebarPalette.resolve(NSAppearance(named: .aqua)!, unreadColor: accent, selectionColor: nil)
        let dark = SidebarPalette.resolve(NSAppearance(named: .darkAqua)!, unreadColor: accent, selectionColor: nil)
        #expect(Self.rgb(light.unread) == [51, 51, 51])
        #expect(Self.rgb(dark.unread) == [204, 204, 204])
        let system = SidebarPalette.resolve(NSAppearance(named: .darkAqua)!, unreadColor: nil, selectionColor: nil)
        #expect(Self.rgb(dark.unread) != Self.rgb(system.unread), "not the system blue")
    }
}
