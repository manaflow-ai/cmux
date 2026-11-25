import AppKit
import CmuxNextTestSupport
@testable import CmuxNextDesign
import Testing

/// Leo 2026-11-21, on the tab hover card: "has a black border... no bueno. no cohesiveness/theme
/// synchronizing! bad." A floating surface's edge is the theme's (rule R6, one stroke from the theme): on
/// Liquid Glass that draws no neutral rim, the surface lays the theme's card rim over the glass's own dark
/// outline; the other materials keep their theme hairline, and Reduce Transparency its opaque path.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OverlayThemeEdgeTests {
    private static let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())

    @Test func theHoverCardsGlassCarriesTheThemeEdge() throws {
        guard Glass.isLiquidGlassAvailable else { return }
        let panel = HoverCardPanel()
        #expect(panel.glass.material == .liquidGlass)
        let edge = try #require(panel.glass.edgeView, "the hover card shows the glass's own dark outline")
        #expect(panel.glass.subviews.last === edge, "the edge draws above the glass and the card's content")
    }

    @Test(arguments: [OverlayTone.theme, .neutralGlass(.transient)])
    func liquidGlassWithNoRimDrawsTheThemesEdge(_ tone: OverlayTone) throws {
        let surface = OverlaySurfaceView(material: .liquidGlass, cornerRadius: 12, reduceTransparency: Self.clear, tone: tone,
                                         glassVariant: .appKitRegular)
        surface.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        surface.applyTheme()
        #expect(surface.rimView == nil, "no second neutral rim")
        let edge = try #require(surface.edgeView)
        let tokens = ThemeScope.app.tokens
        let card = CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
        let wanted = try #require(OverlaySurfaceView.themeEdge(card).usingColorSpace(.sRGB))
        let shown = try #require(edge.color.usingColorSpace(.sRGB))
        #expect(shown.alphaComponent == 1, "opaque, so the glass's dark outline never shows through")
        #expect(abs(shown.redComponent - wanted.redComponent) < 0.02 && abs(shown.greenComponent - wanted.greenComponent) < 0.02
                && abs(shown.blueComponent - wanted.blueComponent) < 0.02, "edge \(shown), wanted the theme's \(wanted)")
        #expect(!(shown.redComponent < 0.02 && shown.greenComponent < 0.02 && shown.blueComponent < 0.02), "a black edge")
    }

    @Test func otherMaterialsAndCardsDrawNoSecondEdge() {
        for material in [OverlayMaterial.vibrancy, .opaque] {
            let surface = OverlaySurfaceView(material: material, reduceTransparency: Self.clear, tone: .neutralGlass(.transient))
            #expect(surface.edgeView == nil, "\(material) keeps its own theme hairline")
        }
        let card = OverlaySurfaceView(material: .liquidGlass, card: true, reduceTransparency: Self.clear)
        #expect(card.edgeView == nil, "a card's tint view draws its rim")
    }

    @Test func clearGlassShowsNoDrawnEdge() throws {
        let surface = OverlaySurfaceView(material: .liquidGlass, reduceTransparency: Self.clear)
        surface.isClear = true
        let edge = try #require(surface.edgeView)
        #expect(edge.isHidden)
    }
}
