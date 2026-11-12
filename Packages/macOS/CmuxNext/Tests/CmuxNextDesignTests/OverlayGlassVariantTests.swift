import AppKit
import CmuxNextTestSupport
@testable import CmuxNextDesign
import Testing

/// Lawrence 2026-11-10, on the glass variant gallery (18 numbered looks on every surface): neither the
/// veil-tinted glass nor the frosted blur "look like proper liquid glass". The floating surfaces (toasts,
/// dialogs and sheets: the neutral glass that casts a shadow) take one numbered variant, picked in one line
/// (``OverlayGlassVariant/picked``). Variant 1 is Apple's Liquid Glass as it ships: no veil tint and no
/// second rim over the glass's own edge. Reduce Transparency keeps the opaque surface.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OverlayGlassVariantTests {
    private static let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())

    private static func surface(_ role: SurfaceRole, _ variant: OverlayGlassVariant,
                                reduceTransparency: ReduceTransparency = clear) -> OverlaySurfaceView {
        let surface = OverlaySurfaceView(interactive: false, cornerRadius: role.cornerRadius, reduceTransparency: reduceTransparency,
                                         tone: role.tone, glassVariant: variant)
        surface.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        surface.applyTheme()
        return surface
    }

    private static func glass(_ surface: OverlaySurfaceView) -> GlassPanelView? {
        surface.subviews.compactMap { $0 as? GlassPanelView }.first
    }

    @Test func thePickedVariantIsAppleLiquidGlass() {
        #expect(OverlayGlassVariant.picked == .appKitRegular)
        #expect(OverlayGlassVariant.picked.rawValue == 1, "the gallery's number")
    }

    @Test(arguments: [SurfaceRole.toast, .sheet])
    func variantOneIsUntintedLiquidGlassWithItsOwnEdge(_ role: SurfaceRole) throws {
        guard Glass.isLiquidGlassAvailable else { return }
        let surface = Self.surface(role, .appKitRegular)
        #expect(surface.material == .liquidGlass)
        let glass = try #require(Self.glass(surface))
        #expect(glass.tintColor == nil, "no veil over Apple's glass")
        #expect(surface.rimView == nil, "the glass's own edge, no second rim")
    }

    @Test(arguments: [SurfaceRole.toast, .sheet])
    func variantThreeKeepsTheVeilTintAndTheRim(_ role: SurfaceRole) throws {
        guard Glass.isLiquidGlassAvailable else { return }
        let surface = Self.surface(role, .veilTinted)
        #expect(surface.material == .liquidGlass)
        #expect(try #require(Self.glass(surface)).tintColor != nil)
        #expect(surface.rimView != nil)
    }

    @Test(arguments: [SurfaceRole.toast, .sheet])
    func variantElevenIsTheFrostWithItsRim(_ role: SurfaceRole) {
        let surface = Self.surface(role, .frost)
        #expect(surface.material == .vibrancy || !Glass.isLiquidGlassAvailable && surface.material != .opaque)
        #expect(surface.rimView != nil)
    }

    @Test(arguments: OverlayGlassVariant.allCases)
    func reduceTransparencyKeepsTheOpaqueSurface(_ variant: OverlayGlassVariant) {
        let surface = Self.surface(.sheet, variant, reduceTransparency: .alwaysOpaque)
        #expect(surface.material == .opaque)
    }

    @Test func aSidebarCardKeepsItsVeilAndRim() throws {
        // The variant is for floating glass only; the sidebar's cards (no shadow) keep their look.
        guard Glass.isLiquidGlassAvailable else { return }
        let surface = Self.surface(.card, .appKitRegular)
        #expect(surface.rimView != nil)
    }
}
