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
}
