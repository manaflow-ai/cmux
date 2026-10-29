import AppKit
import CmuxNextDesign
import QuartzCore

/// The pane chrome (ring, glow, attention ring, border, dim, focus flash) riding its host's render-server
/// spring (chrome-parity R2). Core Animation lays sublayers out for the model bounds
/// only, at commit, so a ring that leaned on its view's size would show its rest size on a pane still
/// growing. Here every sublayer that keeps its thickness gets its own spring, and the host adds them to its
/// own group: one token and one begin time, as cc groups keyframe models that must start together
/// (cc/animation/keyframe_model.h, `group()`). The overlay stays in the plane, above page windows, and is
/// placed once, at rest, when the spring starts (`LayoutViewContext.overlaySyncNow`).
extension PaneOverlayView {
    /// The springs that show this overlay riding its host from `from` (the plane's coordinates, moving at
    /// `velocity`, points per second) to its frame now, its rest, with its opacity from `fromAlpha` to
    /// `toAlpha` of its host's: its own layer's position and size as the host's
    /// (``NSView/renderSpringMoves(from:velocity:)``), its exclusion mask's (``rideMask(from:velocity:)``),
    /// and each sublayer's (``sublayerStart(_:cellChange:)``). Empty outside the plane or hidden. Once the
    /// group is added, ``followRideShadows()`` gives the glowing rings' shadows their springing outlines.
    func rideMoves(from: CGRect, velocity: RectComponents, fromAlpha: CGFloat, toAlpha: CGFloat) -> [RenderSpring.Move] {
        guard !isHidden, let layer else { return [] }
        var moves = renderSpringMoves(from: from, velocity: velocity)
        guard !moves.isEmpty else { return [] }
        if fromAlpha != toAlpha, toAlpha > 0 {
            // Its opacity is the host's times the screen's.
            let rest = CGFloat(layer.opacity)
            moves.append(RenderSpring.Move(layer, .opacity, from: rest * fromAlpha / toAlpha, to: rest))
        }
        moves += rideMask(from: from, velocity: velocity)
        guard from.size != bounds.size else { return moves }
        let change = CGSize(width: from.width - bounds.width, height: from.height - bounds.height)
        let growth = RectComponents(width: velocity.width, height: velocity.height)
        for (sublayer, rest) in sublayerFrames(chromeFrames(cellSize: bounds.size)) {
            moves += Self.springMoves(sublayer, from: Self.sublayerStart(rest, cellChange: change), to: rest, velocity: growth)
        }
        return moves
    }

    /// Where a sublayer resting at `rest` starts when the cell is `cellChange` larger than at rest: it keeps
    /// its distance to the cell's top-left corner and its size changes by the cell's, as the host's content,
    /// laid out at rest, does under its springing bounds. That is `chromeFrames` at every size its clamps
    /// leave alone (at least twice the padding wide, twice the padding plus the bands tall); below them the
    /// rest geometry is an empty rect and the ride's size is negative, and neither draws.
    static func sublayerStart(_ rest: CGRect, cellChange: CGSize) -> CGRect {
        CGRect(origin: rest.origin,
               size: CGSize(width: rest.size.width + cellChange.width, height: rest.size.height + cellChange.height))
    }

    /// The host's spring landed (or was taken back to the CPU): the mask covers the rest bounds again.
    func rideEnded() {
        ridesRenderSpring = false
        endMaskRide()
        layoutLayers()
    }

    /// The host's springs went back to the CPU frames (`ScreenContentView.takeRenderSpringsBack`): the
    /// overlay's position and size springs end with them, and the plane places it on the CPU frames
    /// from now on. A fade keeps running, as the host's does.
    func stopRide() {
        guard let layer else { return }
        for target in [layer] + sublayerFrames(chromeFrames(cellSize: bounds.size)).map({ $0.0 }) {
            RenderSpring.stop(target, "position")
            RenderSpring.stop(target, "bounds.size")
        }
        stopFollowingRideShadows()
        rideEnded()
    }

    /// Scalar springs of `layer`'s position and size from the frame `from` to `to` (its superlayer's
    /// coordinates, an identity transform; `to` is its model frame already), the frame changing at
    /// `velocity`. Origins and sizes are read raw: a start below the clamps has a negative size.
    static func springMoves(_ layer: CALayer, from: CGRect, to: CGRect, velocity: RectComponents) -> [RenderSpring.Move] {
        let anchor = layer.anchorPoint
        func position(_ rect: CGRect) -> CGPoint {
            CGPoint(x: rect.origin.x + anchor.x * rect.size.width, y: rect.origin.y + anchor.y * rect.size.height)
        }
        let start = position(from), rest = position(to)
        let rate = RenderLayerAxes(x: 1, y: 1).velocity(velocity, anchor: anchor)
        return [
            RenderSpring.Move(layer, .positionX, from: start.x, to: rest.x, velocity: rate.position.x),
            RenderSpring.Move(layer, .positionY, from: start.y, to: rest.y, velocity: rate.position.y),
            RenderSpring.Move(layer, .boundsWidth, from: from.size.width, to: to.size.width, velocity: rate.size.width),
            RenderSpring.Move(layer, .boundsHeight, from: from.size.height, to: to.size.height, velocity: rate.size.height),
        ]
    }
}
