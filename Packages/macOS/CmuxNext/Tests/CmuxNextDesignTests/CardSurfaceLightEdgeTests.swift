import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// live-qa on nightly 3a63d6d: the light-mode Update Ready card had no top border. Its sides read
/// about 208 gray, its top about 254, the white sidebar's own. The card draws no layer border off
/// Reduce Transparency, and the card rim's light look fades to white at the top, so over a white
/// sidebar the top edge vanished. 17228e100b1 removed the old all-sides edge (the text at 18%,
/// 0.5 pt). The card keeps a hairline on all four sides in light mode, above the rim (a layer border
/// under it was still hidden at the top on a real screen), and stays the shared glass veil: the
/// hairline is an edge, not a fill.
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

    /// Light mode: a one-pixel hairline of the text color at 12-18% on every side (a border over the
    /// whole card), drawn above the rim, whose white top otherwise covers it; the card is still the
    /// shared card veil with its rim.
    @Test func aLightCardKeepsAHairlineOnEverySide() throws {
        let scope = try Self.scope(dark: false)
        let card = Self.card(in: scope)
        #expect(!card.themeTokens.isDark)
        let rim = try #require(card.rimView)
        let edgeView = try #require(card.edgeView, "the light card draws no hairline")
        let rimIndex = try #require(card.subviews.firstIndex { $0 === rim })
        let edgeIndex = try #require(card.subviews.firstIndex { $0 === edgeView })
        #expect(edgeIndex > rimIndex, "the hairline is under the rim, whose white top hides it")
        card.layoutSubtreeIfNeeded()
        #expect(edgeView.frame == card.bounds, "the hairline does not cover the card: \(edgeView.frame)")
        let edge = try #require(edgeView.layer)
        // One device pixel: 0.5 pt at 2x (the test's card has no window, so 2x), 1 pt at 1x.
        #expect(edge.borderWidth == Metrics.lineWidth(0.5), "the light card's edge is \(edge.borderWidth) pt")
        #expect(CardSurfaceView.hairline(scale: 1) == 1 && CardSurfaceView.hairline(scale: 3) == 1.0 / 3)
        #expect(edge.cornerRadius == card.cornerRadius)
        #expect((edge.backgroundColor?.alpha ?? 0) == 0, "the hairline view paints a fill")
        let color = try #require(edge.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let text = try #require(scope.perform { Palette.textPrimary }.usingColorSpace(.sRGB))
        let share = color.alphaComponent / max(text.alphaComponent, 0.001)
        #expect(share >= 0.12 && share <= 0.18, "the light card's edge is the text at \(share), not 12-18%")
        #expect(abs(color.redComponent - text.redComponent) < 0.01 && abs(color.greenComponent - text.greenComponent) < 0.01
                && abs(color.blueComponent - text.blueComponent) < 0.01, "the light card's edge \(color) is not the text color \(text)")
        // Still glass: the fill is the shared card veil.
        let fill = try #require(card.layer?.backgroundColor)
        let veil = FloatingGlassStyle.card.look(isDark: false).veil
        #expect(abs(fill.alpha - veil.alpha) < 0.02, "the light card's fill is \(fill.alpha), not the veil's \(veil.alpha)")
    }

    /// Dark mode keeps the rim alone (its top edge reads on the dark sidebar).
    @Test func aDarkCardKeepsTheRimAlone() throws {
        let scope = try Self.scope(dark: true)
        let card = Self.card(in: scope)
        #expect(card.themeTokens.isDark)
        #expect(card.edgeView == nil)
        #expect(card.layer?.borderWidth == 0)
        #expect(card.rimView != nil)
    }

    /// Reduce Transparency keeps its opaque fill and separator hairline.
    @Test func reduceTransparencyKeepsTheSeparator() throws {
        let scope = try Self.scope(dark: false)
        let card = Self.card(in: scope, reduceTransparency: true)
        #expect(card.layer?.borderWidth == Metrics.lineWidth(1))
        #expect(card.rimView == nil)
        #expect(card.edgeView == nil)
    }
}
