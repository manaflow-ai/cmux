import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// cx-abv: the Home sidebar's unread dot uses the app's theme accent (`Palette.accent`) in
/// light and dark; only sent bubbles are iMessage blue.
@MainActor @Suite(.serialized) struct HomeSidebarAccentTests {
    private static func rgba(_ c: NSColor?) -> [CGFloat] {
        guard let s = c?.usingColorSpace(.sRGB) else { return [] }
        return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { ($0 * 255).rounded() }
    }

    @Test func theUnreadDotIsTheThemeAccentInLightAndDark() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let view = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
            view.appearance = NSAppearance(named: name)
            view.applyColors()
            let accent = view.performWithTheme { Self.rgba(Palette.accent) }
            #expect(!accent.isEmpty && Self.rgba(view.list.unreadColor) == accent, "\(name.rawValue)")
            #expect(Self.rgba(view.list.unreadColor) != Self.rgba(.systemBlue), "\(name.rawValue): not the system blue")
        }
    }
}
