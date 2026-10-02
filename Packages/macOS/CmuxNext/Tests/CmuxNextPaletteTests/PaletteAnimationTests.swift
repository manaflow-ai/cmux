import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import QuartzCore
import Testing

/// The palette scales in and out about its own center,
/// never about an edge. AppKit gives a view's backing layer
/// an anchor point of (0, 0), so a transform must pivot explicitly.
@MainActor
struct PaletteAnimationTests {
    /// Where `transform` (as the layer's sublayerTransform) draws `point`,
    /// in the layer's bounds coordinates: Core Animation applies it about
    /// the layer's anchor point.
    func rendered(_ point: CGPoint, by transform: CATransform3D, in layer: CALayer) -> CGPoint {
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let affine = CATransform3DGetAffineTransform(transform)
        let moved = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y).applying(affine)
        return CGPoint(x: moved.x + anchor.x, y: moved.y + anchor.y)
    }

    @Test func openAndCloseScaleAboutThePanelCenter() throws {
        let view = PaletteContentView(model: PaletteModel(persistence: nil))
        view.frame = NSRect(origin: .zero, size: PaletteLayout.windowSize)
        view.layoutSubtreeIfNeeded()
        let layer = try #require(view.layer)
        let center = view.panelCenter
        for scale in [Motion.panelOpenScale, Motion.panelCloseScale] {
            let point = rendered(center, by: view.panelScale(scale), in: layer)
            #expect(abs(point.x - center.x) < 0.01 && abs(point.y - center.y) < 0.01,
                    "scale \(scale) moves the panel center \(center) to \(point) (anchor \(layer.anchorPoint))")
        }
    }
}
