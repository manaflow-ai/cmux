import AppKit
import Testing
@testable import CmuxNextDesign

/// Vibrancy under the sidebar and tab strips: tinted from the view's theme
/// scope, shown only in a see-through window, and never in the way of a click.
@MainActor @Suite(.serialized) struct ChromeBackdropViewTests {
    private func backdrop(in input: ThemeInput, named name: String) -> (ChromeBackdropView, ThemeScope) {
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec(name)!, input: input, animated: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        room.root(host)
        let backdrop = ChromeBackdropView(material: .sidebar) { Palette.sidebarBackground }
        backdrop.frame = host.bounds
        host.addSubview(backdrop)
        backdrop.viewDidChangeEffectiveAppearance()
        return (backdrop, room)
    }

    private func expectTint(_ backdrop: ChromeBackdropView, _ expected: ThemeRGB, alpha: Double) throws {
        let tint = try #require(backdrop.tintColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(abs(tint.redComponent - expected.red) < 0.01)
        #expect(abs(tint.greenComponent - expected.green) < 0.01)
        #expect(abs(tint.blueComponent - expected.blue) < 0.01)
        #expect(abs(tint.alphaComponent - alpha) < 0.01)
    }

    /// An opaque window keeps the solid theme color it had before vibrancy.
    @Test func anOpaqueWindowGetsTheSolidThemeColor() throws {
        let (backdrop, _) = backdrop(in: ThemeFixtures.gruvboxDark, named: "Gruvbox Dark")
        #expect(!backdrop.showsBlur)
        try expectTint(backdrop, ThemeTokens.derive(from: ThemeFixtures.gruvboxDark).sidebarBackground, alpha: 1)
    }

    /// A see-through window shows the blur under the theme color at the tint opacity.
    @Test func aTranslucentWindowBlursUnderTheTint() throws {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.85
        let (backdrop, _) = backdrop(in: input, named: "Catppuccin Mocha")
        let effect = try #require(backdrop.subviews.first as? NSVisualEffectView)
        #expect(backdrop.showsBlur)
        #expect(effect.blendingMode == .behindWindow)
        #expect(effect.state == .active)
        try expectTint(backdrop, ThemeTokens.derive(from: input).sidebarBackground,
                       alpha: 0.85 * ChromeBackdropView.defaultTintOpacity)
    }

    /// A theme change reaches the chrome without a relaunch, including the switch to opaque.
    @Test func aThemeChangeUpdatesTheTint() throws {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.85
        let (backdrop, room) = backdrop(in: input, named: "Catppuccin Mocha")
        room.setOverride(ThemeSpec("GitHub Light")!, input: ThemeFixtures.githubLight, animated: false)
        backdrop.viewDidChangeEffectiveAppearance()
        #expect(!backdrop.showsBlur)
        try expectTint(backdrop, ThemeTokens.derive(from: ThemeFixtures.githubLight).sidebarBackground, alpha: 1)
    }

    @Test func clicksPassThrough() {
        let backdrop = ChromeBackdropView(material: .headerView) { Palette.stripBackground }
        backdrop.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(backdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
