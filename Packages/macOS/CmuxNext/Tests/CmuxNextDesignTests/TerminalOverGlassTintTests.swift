@testable import CmuxNextDesign
import Foundation
import Testing

/// Terminals over a glass window show the glass (Leo, 2026-10-18: "if we're doing glass, we're doing
/// glass, period"). Glass at the default Opacity 1 tinted the Liquid Glass at alpha 1, so the window,
/// and every terminal over it, was the solid theme colour. The glass tint now stops at
/// ``ThemeTokens/glassTintCeiling``, the reference's theme background at about 40% (hq
/// docs/design/glass-raycast-parity.md), while an opaque window and Reduce Transparency stay solid.
@MainActor @Suite struct TerminalOverGlassTintTests {
    static let dark = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
    static let light = ThemeInput(background: ThemeRGB(hex: 0xFFFCF0), foreground: ThemeRGB(hex: 0x100F0F))
    /// A saturated stand-in for whatever is behind the window (desktop or picture).
    static let standIn = ThemeRGB(hex: 0xD02060)

    static func tokens(_ input: ThemeInput, blur: Int, opacity: Double = 1) -> ThemeTokens {
        var input = input
        input.backgroundBlur = blur
        input.backgroundOpacity = opacity
        return ThemeTokens.derive(from: input)
    }

    /// The share of the stand-in that shows through the tint under a terminal pane.
    static func showThrough(_ tokens: ThemeTokens, _ backdrop: WindowBackdrop) -> Double {
        let bg = tokens.windowBackground.withAlpha(1)
        let shown = bg.withAlpha(backdrop.tintOpacity).composited(over: standIn)
        let channels = [(shown.red, bg.red, standIn.red), (shown.green, bg.green, standIn.green), (shown.blue, bg.blue, standIn.blue)]
        let spread = channels.map { abs($0.2 - $0.1) }.max() ?? 0
        guard spread > 0 else { return 0 }
        return (channels.map { abs($0.0 - $0.1) }.max() ?? 0) / spread
    }

    @Test(arguments: [-1, -2], [true, false])
    func glassAtFullOpacityIsNotSolid(blur: Int, dark: Bool) {
        let tokens = Self.tokens(dark ? Self.dark : Self.light, blur: blur)
        let backdrop = WindowBackdrop(tokens)
        #expect(!backdrop.isOpaque)
        #expect(backdrop.tintOpacity < 1, "glass at Opacity 1 tints at \(backdrop.tintOpacity)")
        // The composite under a terminal over the stand-in is not the solid theme colour.
        #expect(Self.showThrough(tokens, backdrop) > 0.3,
                "only \(Self.showThrough(tokens, backdrop)) of the backdrop shows under a terminal")
    }

    @Test func glassAtFullOpacityMatchesTheReference() {
        #expect(abs(WindowBackdrop(Self.tokens(Self.dark, blur: -1)).tintOpacity - 0.40) < 0.001)
        #expect(abs(WindowBackdrop(Self.tokens(Self.light, blur: -1)).tintOpacity - 0.55) < 0.001)
    }

    /// Over a picture the glass stops at the same ceiling, not the theme's denser picture tint.
    @Test func glassOverAPictureIsNotASlab() {
        let tokens = Self.tokens(Self.dark, blur: -1)
        let picture = BackdropSelection.art(.vanGoghStarryNight)
        #expect(WindowBackdrop(tokens, selection: picture).tintOpacity <= tokens.glassTintCeiling)
        #expect(WindowBackdrop(tokens, selection: picture, tintOpacity: 1).tintOpacity <= tokens.glassTintCeiling)
    }

    /// Opacity below the ceiling is kept as asked.
    @Test func glassBelowTheCeilingKeepsItsOpacity() {
        #expect(WindowBackdrop(backgroundOpacity: 0.25, backgroundBlur: -1, liquidGlass: true).tintOpacity == 0.25)
    }

    /// No default flips: the default material, an opaque window and Reduce Transparency stay solid.
    @Test func opaqueStaysSolid() {
        let plain = WindowBackdrop(Self.tokens(Self.dark, blur: 0))
        #expect(plain.isOpaque && plain.tintOpacity == 1)
        let reduced = WindowBackdrop(Self.tokens(Self.dark, blur: -1), reduceTransparency: true)
        #expect(reduced.isOpaque && reduced.tintOpacity == 1)
        #expect(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault)).isOpaque)
    }

    /// The chrome's quieter inks are derived over the glass tint on the worst desktop, as a translucent
    /// window's are: secondary text is muted no further than 4.5:1 there, or not at all where the primary
    /// itself reads less. Before, glass at Opacity 1 derived them as opaque, muted over the theme fill alone.
    @Test(arguments: [true, false])
    func quieterInksAreDerivedOverTheGlassTint(dark: Bool) {
        let tokens = Self.tokens(dark ? Self.dark : Self.light, blur: -1)
        let bg = tokens.windowBackground.withAlpha(1)
        let tint = bg.withAlpha(tokens.glassTintCeiling).composited(over: tokens.isDark ? .white : .black)
        let floor = min(ThemeTokens.minimumTextContrast, tokens.textPrimary.contrast(with: tint))
        #expect(tokens.textSecondary.contrast(with: tint) >= floor - 0.05,
                "secondary text reads \(tokens.textSecondary.contrast(with: tint)) on the glass tint, under \(floor)")
        let opaque = Self.tokens(dark ? Self.dark : Self.light, blur: 0)
        #expect(tokens.textSecondary.contrast(with: tint) >= opaque.textSecondary.contrast(with: tint) - 0.05,
                "glass mutes secondary text further than an opaque window")
    }
}
