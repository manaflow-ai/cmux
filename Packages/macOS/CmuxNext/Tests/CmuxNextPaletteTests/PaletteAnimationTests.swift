import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import QuartzCore
import Testing

/// The palette scales in and out about its own center,
/// never about an edge. AppKit gives a view's backing layer
/// an anchor point of (0, 0), so a transform must pivot explicitly.
@MainActor @Suite(.serialized, .paletteRanker)
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

    func makeView() -> PaletteContentView {
        let view = PaletteContentView(model: PaletteModel(persistence: nil))
        view.frame = NSRect(origin: .zero, size: PaletteLayout.windowSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Reduce Motion: the close is a crossfade only; the shrink applies at
    /// once (motion.md rule 7: movement is instant, opacity stays a fade).
    @Test(arguments: [false, true])
    func closeShrinksOnlyWhileMovementAnimates(reduceMotion: Bool) throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let view = makeView()
        let layer = try #require(view.layer)
        view.animateOut {}
        #expect(layer.animation(forKey: "opacity") != nil)
        #expect((layer.animation(forKey: "sublayerTransform") != nil) == !reduceMotion)
        view.resetAnimations()
    }

    /// The Cmd-K Actions menu grows from, and shrinks toward, the footer's
    /// "Actions ⌘K" corner (its bottom trailing corner), never an edge.
    @Test func actionsMenuScalesAboutItsFooterCorner() throws {
        let view = makeView()
        let menu = view.actionsMenuView
        menu.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        let layer = try #require(menu.layer)
        let pivot = menu.scalePivot
        #expect(pivot == CGPoint(x: 240, y: 0))
        for scale in [Motion.panelOpenScale, Motion.panelCloseScale] {
            let point = rendered(pivot, by: menu.scaled(scale), in: layer)
            #expect(abs(point.x - pivot.x) < 0.01 && abs(point.y - pivot.y) < 0.01, "scale \(scale) moves the corner to \(point)")
        }
    }

    /// Opening the Actions menu springs its scale in, and closing shrinks
    /// it; under Reduce Motion only the opacity fades.
    @Test(arguments: [false, true])
    func actionsMenuOpenAndCloseAnimateItsScaleUnlessReduceMotion(reduceMotion: Bool) throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let view = makeView()
        let menu = view.actionsMenuView
        menu.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        let layer = try #require(menu.layer)
        view.animateActionsMenu(appearing: true)
        #expect(!menu.isHidden)
        #expect((layer.animation(forKey: "sublayerTransform") != nil) == !reduceMotion)
        layer.removeAllAnimations()
        view.animateActionsMenu(appearing: false)
        #expect((layer.animation(forKey: "sublayerTransform") != nil) == !reduceMotion)
    }
}
