import AppKit
import Testing
@testable import CmuxNextDesign

/// Vibrancy under the sidebar and tab strips: tinted from the view's theme
/// scope, always active, and never in the way of a click.
@MainActor @Suite(.serialized) struct ChromeBackdropViewTests {
    @Test func theTintIsTheScopesColorAtTheTintOpacity() throws {
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Gruvbox Dark")!, input: ThemeFixtures.gruvboxDark, animated: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        room.root(host)
        let backdrop = ChromeBackdropView(material: .sidebar) { Palette.sidebarBackground }
        backdrop.frame = host.bounds
        host.addSubview(backdrop)
        backdrop.viewDidChangeEffectiveAppearance()

        let effect = try #require(backdrop.subviews.first as? NSVisualEffectView)
        #expect(effect.blendingMode == .behindWindow)
        #expect(effect.state == .active)
        let tint = try #require(backdrop.subviews.last?.layer?.backgroundColor)
        let expected = ThemeTokens.derive(from: ThemeFixtures.gruvboxDark).sidebarBackground
        let components = try #require(NSColor(cgColor: tint)?.usingColorSpace(.sRGB))
        #expect(abs(components.redComponent - expected.red) < 0.01)
        #expect(abs(components.alphaComponent - ChromeBackdropView.defaultTintOpacity) < 0.01)
    }

    @Test func clicksPassThrough() {
        let backdrop = ChromeBackdropView(material: .headerView) { Palette.stripBackground }
        backdrop.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(backdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
