import AppKit
@testable import CmuxNextDesign
import Testing

/// The App's whole native surface under a web surface (host glass, `Glass.makeHostSurface`): the page lays
/// only its content on it, so each level must be the surface the native UI draws for it (the Liquid Glass
/// Parity playground diffs the two to the pixel; Lawrence 2026-11-18).
@MainActor @Suite struct HostGlassSurfaceTests {
    /// A web tooltip's glass is the tooltip window's whole surface: the legibility tint over the glass and
    /// the tooltip's small shadow, as TooltipPanel draws them (before, bare glass with neither).
    @Test func aChipIsTheTooltipsWholeSurface() {
        let surface = Glass.makeHostSurface(level: .chip)
        #expect(surface.contentView.subviews.first is TooltipLegibilityView)
        #expect(surface.castShadow == TooltipSurface.shadow)
        #expect(surface.cornerRadius == SurfaceRole.tooltip.cornerRadius)
    }

    @Test func theTooltipGlassCastsItsShadowAlongItsShapeAtAnySize() throws {
        let surface = Glass.makeTooltipGlass(cornerRadius: 6)
        surface.frame = CGRect(x: 0, y: 0, width: 180, height: 56)
        let layer = try #require(surface.layer)
        #expect(layer.shadowOpacity == Float(TooltipSurface.shadow.alpha))
        #expect(layer.shadowPath?.boundingBox == CGRect(x: 0, y: 0, width: 180, height: 56))
        surface.frame.size = CGSize(width: 120, height: 30)
        #expect(layer.shadowPath?.boundingBox == CGRect(x: 0, y: 0, width: 120, height: 30))
        surface.castShadow = nil
        #expect(layer.shadowOpacity == 0)
    }

    /// Docked glass is the theme's glass at the chrome level's tint (the tab strip's, a drag ghost's),
    /// not a popover's transient material.
    @Test func chromeIsTheThemesGlassAtTheChromeLevel() {
        let surface = Glass.makeHostSurface(level: .chrome)
        #expect(surface.tintLevel == .chrome)
        #expect(surface.tone == .theme)
        #expect(surface.castShadow == nil)
        #expect(Glass.hostTintLevel(.chrome) == .chrome)
    }

    @Test func menusAndPopoversKeepTheirOwnSurfaces() {
        #expect(Glass.makeHostSurface(level: .menu).contentView.subviews.first is GlassMenuVeilView)
        #expect(Glass.makeHostSurface(level: .popover).tone == .neutralGlass(.transient))
        #expect(Glass.makeHostSurface(level: .popover).castShadow == nil)
    }
}
