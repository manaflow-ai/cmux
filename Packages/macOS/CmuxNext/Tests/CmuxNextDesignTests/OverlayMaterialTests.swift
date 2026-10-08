import AppKit
import Testing
@testable import CmuxNextDesign

/// Dogfood nxdog14: "ensure drop overlay is true liquid glass for macos
/// versions that support it. handle well for macos versions that don't".
/// One decision picks the drop overlay's material for every OS and
/// accessibility case; every material keeps the same shape.
@MainActor @Suite struct OverlayMaterialTests {
    @Test func liquidGlassWhereTheOSHasIt() {
        #expect(OverlayMaterial.select(liquidGlassAvailable: true, reduceTransparency: false) == .liquidGlass)
    }

    @Test func aBlurBeforeLiquidGlass() {
        #expect(OverlayMaterial.select(liquidGlassAvailable: false, reduceTransparency: false) == .vibrancy)
    }

    @Test func reduceTransparencyIsOpaqueOnEveryOS() {
        #expect(OverlayMaterial.select(liquidGlassAvailable: true, reduceTransparency: true) == .opaque)
        #expect(OverlayMaterial.select(liquidGlassAvailable: false, reduceTransparency: true) == .opaque)
    }

    @Test func thisMacHasLiquidGlass() {
        // cmux-next requires macOS 26, the first release with Liquid Glass.
        #expect(OverlayMaterial.liquidGlassAvailable)
    }

    @Test func eachMaterialDrawsWithItsOwnView() {
        let glass = OverlaySurfaceView(material: .liquidGlass)
        #expect(glass.materialDrawingView is NSGlassEffectView)
        let blur = OverlaySurfaceView(material: .vibrancy)
        #expect(blur.materialDrawingView is NSVisualEffectView)
        let opaque = OverlaySurfaceView(material: .opaque)
        #expect(!(opaque.materialDrawingView is NSVisualEffectView) && !(opaque.materialDrawingView is NSGlassEffectView))
        #expect((opaque.materialDrawingView?.layer?.backgroundColor?.alpha ?? 0) == 1)
    }

    @Test func everyMaterialHasTheSameShape() {
        for material in [OverlayMaterial.liquidGlass, .vibrancy, .opaque] {
            let surface = OverlaySurfaceView(material: material)
            surface.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
            surface.cornerRadius = 14
            let view = surface.materialDrawingView
            #expect(view?.frame == surface.bounds, "\(material)")
            if let glass = view as? NSGlassEffectView {
                #expect(glass.cornerRadius == 14)
            } else {
                #expect(view?.layer?.cornerRadius == 14, "\(material)")
                #expect(view?.layer?.cornerCurve == .continuous, "\(material)")
            }
        }
    }

    @Test func pinningAMaterialSwapsTheDrawingViewAndKeepsTheContent() {
        let surface = OverlaySurfaceView(material: .liquidGlass)
        let label = NSTextField(labelWithString: "Split")
        surface.contentView.addSubview(label)
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        for material in [OverlayMaterial.opaque, .vibrancy, .liquidGlass, .opaque] {
            surface.materialOverride = material
            surface.layoutSubtreeIfNeeded()
            // The content fills the surface on every path (the label stays centered).
            let frame = surface.contentView.convert(surface.contentView.bounds, to: surface)
            #expect(frame == surface.bounds, "\(material): \(frame)")
        }
        #expect(surface.material == .opaque)
        #expect(label.superview === surface.contentView)
        #expect(surface.contentView.isDescendant(of: surface))
    }
}
