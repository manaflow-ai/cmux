import AppKit
@testable import CmuxNextDesign
import Testing

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

    /// The default adds no overlay, at every opacity and for both glass styles.
    @Test func inactiveGlassDoesNotAddASecondTint() {
        for material in Self.glassMaterials {
            for opacity in [0.0, 0.3, 0.55, 0.8, 1.0] {
                #expect(WindowMaterialView.inactiveTintAlpha(material: material, isKeyWindow: false, tintAlpha: opacity, dim: 0) == 0)
            }
        }
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

    /// An explicit dim keeps its configured strength and stays in 0...1.
    @Test func theDimCoversItsShareOfWhatShowsThrough() {
        let dimmed = WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 0.25)
        #expect(abs(dimmed - 0.25) < 0.0001)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 1) == 1)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: 7) == 1)
        #expect(WindowMaterialView.inactiveTintAlpha(material: .glass(.regular), isKeyWindow: false, tintAlpha: 0.55, dim: -1) == matched)
    }
}
