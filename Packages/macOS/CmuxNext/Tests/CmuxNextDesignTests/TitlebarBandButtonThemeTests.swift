import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// User report 2026-11-03 (cmux NEXT, dark theme): the top-left toolbar icons (sidebar toggle,
/// Back, Forward) had too little contrast. A `TitlebarBandButton` read its glyph ink once, in
/// `init`, before it was in any window or theme scope, and had no theme hook: a theme or
/// light/dark change later kept the old theme's grey on the new titlebar.
@MainActor @Suite(.serialized) struct TitlebarBandButtonThemeTests {
    /// A light theme, then a dark one whose secondary ink no default theme has, so a stale ink
    /// cannot match it by chance.
    private static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328))
    private static let dark = ThemeInput(background: ThemeRGB(hex: 0x102030), foreground: ThemeRGB(hex: 0xF0C080))

    /// A band button in a room scope painted with the light theme, and the host that roots the
    /// scope (the scope holds its roots weakly: the caller keeps it).
    private func lightBand() throws -> (TitlebarBandButton, NSView, ThemeScope) {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Band Light"), input: Self.light, animated: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        scope.root(host)
        let button = TitlebarBandButton(symbol: "chevron.left")
        host.addSubview(button)
        return (button, host, scope)
    }

    @Test func aThemeChangeRepaintsTheGlyphInk() throws {
        let (button, host, scope) = try lightBand()
        // The theme repaint runs every view's hook in the scope (`ThemeRepaint`), as a theme
        // switch or a light/dark change does in the app.
        scope.setOverride(ThemeSpec("Band Dark"), input: Self.dark, animated: false)

        #expect(button.superview === host)
        let ink = try #require(button.contentTintColor)
        let want = scope.perform { Palette.textSecondary }
        #expect(Self.same(ink, want), "the glyph kept the ink it read before the theme changed")
        let tokens = scope.tokens
        let rgb = try #require(ink.usingColorSpace(.sRGB))
        let drawn = ThemeRGB(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
            .withAlpha(Double(rgb.alphaComponent))
        let ground = tokens.windowBackground.withAlpha(1)
        #expect(drawn.composited(over: ground).contrast(with: ground) >= 3, "a toolbar glyph reads at 3:1 on its titlebar")
    }

    /// An owner's ink (a lit pane tool, the host pressure warning) stays across the repaint: the
    /// owner's hook runs first and sets it again, and the button's own hook must not drop it.
    @Test func anOwnersInkSurvivesTheRepaint() throws {
        let (button, host, scope) = try lightBand()
        let lit = NSColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        button.tintOverride = lit
        scope.setOverride(ThemeSpec("Band Dark"), input: Self.dark, animated: false)
        #expect(button.superview === host)
        #expect(Self.same(try #require(button.contentTintColor), lit))
        button.tintOverride = nil
        #expect(Self.same(try #require(button.contentTintColor), scope.perform { Palette.textSecondary }))
    }

    private static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
