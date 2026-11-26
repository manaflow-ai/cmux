import AppKit
@testable import CmuxNextDesign
import Testing

/// Leo 2026-10-20: the hover card should look like iOS's refracting glass. It is the app's one
/// overlay glass (`OverlaySurfaceView`: themed Liquid Glass with its own refracting rim, vibrancy
/// before macOS 26, solid under Reduce Transparency), shaped like the other floating glass panels
/// rather than a menu, and before macOS 26 it blurs what is under it.
@MainActor @Suite(.serialized) struct HoverCardGlassTests {
    /// The floating glass panels' continuous radius (the palette, dialogs), not the menus'
    /// 8 pt, and the shadow follows the same shape.
    @Test func theCardTakesTheFloatingGlassPanelRadius() throws {
        let panel = HoverCardPanel()
        #expect(panel.glass.cornerRadius == Metrics.panelCornerRadius)
        let host = try #require(panel.contentView as? PopupHostView)
        #expect(host.cornerRadius == Metrics.panelCornerRadius, "the shadow does not follow the card's corners")
    }

    /// The card is the whole content of its own clear window, so a blur within that window has
    /// nothing under it: the fallback blurs what is behind the window (the sidebar, the
    /// terminal), as its Liquid Glass refracts it.
    @Test func theFallbackGlassBlursWhatIsBehindTheCardsWindow() throws {
        let panel = HoverCardPanel()
        panel.glass.materialOverride = .vibrancy
        defer { panel.glass.materialOverride = nil }
        let effect = try #require(panel.glass.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(effect.blendingMode == .behindWindow)
        #expect(effect.state == .active)
    }

    /// An overlay inside a window (a find bar over a pane) still blurs that window's content.
    @Test func anOverlayInsideAWindowStillBlursWithinIt() throws {
        let surface = OverlaySurfaceView(material: .vibrancy, interactive: true)
        let effect = try #require(surface.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(effect.blendingMode == .withinWindow)
    }

    /// Leo 2026-11-22, the tab hover card: "has a black border... no cohesiveness/theme synchronizing";
    /// "doubled up glass/wack looking glass all over the place". Liquid Glass casts its own soft shadow, so
    /// the popup host's black one under it was a second shadow that read as a dark ring: the host lays none
    /// under real Liquid Glass and keeps its shadow under the blur and the solid card, which cast none.
    @Test func theHostCastsNoSecondShadowUnderLiquidGlass() throws {
        let panel = HoverCardPanel()
        let host = try #require(panel.contentView as? PopupHostView)
        host.setFrameSize(NSSize(width: 320, height: 200))
        for material in [OverlayMaterial.liquidGlass, .vibrancy, .opaque] {
            panel.glass.materialOverride = material
            host.layoutSubtreeIfNeeded()
            host.layout()
            let systemShadow = panel.glass.castsSystemGlassShadow
            #expect(host.shadowLayer.opacity == (systemShadow ? 0 : 1), "\(material)")
            if material != .liquidGlass { #expect(!systemShadow, "\(material) casts no shadow of its own") }
        }
        panel.glass.materialOverride = nil
    }
}
