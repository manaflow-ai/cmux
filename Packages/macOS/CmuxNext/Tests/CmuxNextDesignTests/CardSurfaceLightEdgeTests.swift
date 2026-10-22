import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// live-qa on nightly 3a63d6d: the light-mode Update Ready card had no top border. Its sides read
/// about 208 gray, its top about 254, the white sidebar's own. The card draws no layer border off
/// Reduce Transparency, and the card rim's light look fades to white at the top, so over a white
/// sidebar the top edge vanished. 17228e100b1 removed the old all-sides edge (the text at 18%,
/// 0.5 pt). The card keeps a hairline on all four sides in light mode, and stays the shared glass
/// veil: the hairline is an edge, not a fill.
@MainActor @Suite(.serialized) struct CardSurfaceLightEdgeTests {
    private static func scope(dark: Bool) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        scope.setOverride(try #require(ThemeSpec("Card Edge \(dark ? "dark" : "light")")), input: input, animated: false)
        return scope
    }

    private static func card(in scope: ThemeScope, reduceTransparency: Bool = false) -> CardSurfaceView {
        let card = CardSurfaceView(reduceTransparency: ReduceTransparency(system: { reduceTransparency }, changes: NotificationCenter()))
        card.frame = NSRect(x: 0, y: 0, width: 216, height: 120)
        scope.root(card)
        card.updateLayer()
        return card
    }

    /// Light mode: a 0.5 pt hairline of the text color at 12-18%, on every side (a layer border),
    /// over the shared card veil.
    @Test func aLightCardKeepsAHairlineOnEverySide() throws {
        let scope = try Self.scope(dark: false)
        let card = Self.card(in: scope)
        #expect(!card.themeTokens.isDark)
        let layer = try #require(card.layer)
        #expect(layer.borderWidth == Metrics.lineWidth(0.5), "the light card's edge is \(layer.borderWidth) pt")
        let edge = try #require(layer.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let text = try #require(scope.perform { Palette.textPrimary }.usingColorSpace(.sRGB))
        let share = edge.alphaComponent / max(text.alphaComponent, 0.001)
        #expect(share >= 0.12 && share <= 0.18, "the light card's edge is the text at \(share), not 12-18%")
        #expect(abs(edge.redComponent - text.redComponent) < 0.01 && abs(edge.greenComponent - text.greenComponent) < 0.01
                && abs(edge.blueComponent - text.blueComponent) < 0.01, "the light card's edge \(edge) is not the text color \(text)")
        // Still glass: the fill is the shared card veil, and the rim still draws.
        let fill = try #require(layer.backgroundColor)
        let veil = FloatingGlassStyle.card.look(isDark: false).veil
        #expect(abs(fill.alpha - veil.alpha) < 0.02, "the light card's fill is \(fill.alpha), not the veil's \(veil.alpha)")
        #expect(card.rimView != nil)
    }

    /// Dark mode keeps the rim alone (its top edge reads on the dark sidebar).
    @Test func aDarkCardKeepsTheRimAlone() throws {
        let scope = try Self.scope(dark: true)
        let card = Self.card(in: scope)
        #expect(card.themeTokens.isDark)
        #expect(card.layer?.borderWidth == 0)
        #expect(card.rimView != nil)
    }

    /// Reduce Transparency keeps its opaque fill and separator hairline.
    @Test func reduceTransparencyKeepsTheSeparator() throws {
        let scope = try Self.scope(dark: false)
        let card = Self.card(in: scope, reduceTransparency: true)
        #expect(card.layer?.borderWidth == Metrics.lineWidth(1))
        #expect(card.rimView == nil)
    }
}
