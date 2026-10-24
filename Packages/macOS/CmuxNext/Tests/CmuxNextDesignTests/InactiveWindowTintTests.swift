import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-20: "it's so weird when the app is in focus and out of focus; the opacity shifts
/// in weird hardcoded ways." A window that is not key looks like the key one: the wash over
/// inactive glass follows the Opacity the person set (not 0.85 for a dark theme and 0.35 for a
/// light one), and only `appearance.inactiveWindowDim` makes it darker.
@MainActor @Suite struct InactiveWindowTintTests {
    static let glassMaterials: [WindowMaterial] = [.glass(.regular), .glass(.clear)]

    /// A key window never has a wash, whatever the material or dim.
    @Test func aKeyWindowHasNoWash() {
        for material in Self.glassMaterials + [.frosted, .translucent, .opaque] {
            for dim in [0.0, 0.3, 1.0] {
                #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: true, tintAlpha: 0.55, dim: dim) == 0)
            }
        }
    }

    /// Over inactive glass the wash replaces the tint Liquid Glass dropped: it follows the
    /// Opacity, so 0.55 and 0.8 differ, and dark and light themes get the same coverage.
    @Test func theGlassWashFollowsTheOpacity() {
        for material in Self.glassMaterials {
            var last: CGFloat = -1
            for opacity in [0.0, 0.3, 0.55, 0.8, 1.0] {
                let wash = WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, tintAlpha: opacity, dim: 0)
                #expect(wash == WindowMaterialView.matchedGlassWash(tintAlpha: opacity))
                #expect(wash > last || (wash == 1 && last == 1), "the wash grows with the opacity (\(opacity): \(wash))")
                #expect((0...1).contains(wash))
                last = wash
            }
            #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, tintAlpha: 0, dim: 0) == 0)
        }
        // Leo's setup, Opacity 0.55 with Glass: the old wash was 0.85 of the tint over a dark theme;
        // now the inactive window shows the tint at the Opacity it showed while key.
        let leo = WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 0)
        #expect(abs(leo - 0.55) < 0.0001)
    }

    /// Materials whose tint does not depend on the key state get no wash unless the person asks
    /// for a dim; an opaque window never does (theme color over the same theme color).
    @Test func otherMaterialsOnlyDimWhenAsked() {
        for material: WindowMaterial in [.frosted, .translucent] {
            #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, tintAlpha: 0.55, dim: 0) == 0)
            #expect(abs(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, tintAlpha: 0.55, dim: 0.2) - 0.2) < 0.0001)
        }
        #expect(WindowMaterialView.inactiveTintAlpha(material: .opaque, isKeyWindow: false, tintAlpha: 1, dim: 0.5) == 0)
    }

    /// The dim covers that share of what still shows through the matched wash, and stays in 0...1.
    @Test func theDimCoversItsShareOfWhatShowsThrough() {
        let matched = WindowMaterialView.matchedGlassWash(tintAlpha: 0.55)
        let dimmed = WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 0.25)
        #expect(abs(dimmed - (matched + 0.25 * (1 - matched))) < 0.0001)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 1) == 1)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 7) == 1)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: -1) == matched)
    }

    /// Leo, 2026-10-23: an inactive window may shield the desktop that native glass reveals, but
    /// its wash must stay below the person's in-app background. The focus transition therefore
    /// keeps the same art layer visible instead of dimming it with the inactive tint.
    @Test func theInactiveWashStaysBehindInAppArt() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let wash = view.subviews.firstIndex(of: view.inactiveTintView)
        let art = view.subviews.firstIndex(of: view.artView)
        #expect(wash != nil && art != nil && wash! < art!, "the desktop shield must be below the in-app background")
    }
}
