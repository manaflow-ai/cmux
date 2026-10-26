import AppKit
import CmuxNextDesign
import QuartzCore

/// The pane chrome (ring, glow, attention ring, border, dim, focus flash) riding its host's render-server
/// spring (chrome-parity R2, p03-rendering-029). Core Animation lays sublayers out for the model bounds
/// only, at commit, so a ring that leaned on its view's size would show its rest size on a pane still
/// growing. Here every sublayer that keeps its thickness gets its own spring, from its frame at the size
/// the pane showed to its frame at rest (`PaneMotionPlan.ChromeFrames`), and the host adds them to its own
/// group: one token and one begin time, as cc groups keyframe models that must start together
/// (cc/animation/keyframe_model.h, `group()`). The overlay stays in the plane, above page windows, and is
/// placed once, at rest, when the spring starts (`LayoutViewContext.overlaySyncNow`).
extension PaneOverlayView {
    /// The springs that show this overlay riding its host from `from` (the plane's coordinates, moving at
    /// `velocity`, points per second) to its frame now, its rest, with its opacity from `fromAlpha` to
    /// `toAlpha` of its host's: its own layer's position and size as the host's
    /// (``NSView/renderSpringMoves(from:velocity:)``), and each sublayer's from its frame at the `from`
    /// size. Empty outside the plane or hidden. A glowing attention ring drops its fixed outline until
    /// ``rideEnded()``.
    func rideMoves(from: CGRect, velocity: RectComponents, fromAlpha: CGFloat, toAlpha: CGFloat) -> [RenderSpring.Move] {
        guard !isHidden, let layer else { return [] }
        var moves = renderSpringMoves(from: from, velocity: velocity)
        guard !moves.isEmpty else { return [] }
        if fromAlpha != toAlpha, toAlpha > 0 {
            // Its opacity is the host's times the screen's.
            let rest = CGFloat(layer.opacity)
            moves.append(RenderSpring.Move(layer, "opacity", from: rest * fromAlpha / toAlpha, to: rest))
        }
        guard from.size != bounds.size else { return moves }
        // Each sublayer keeps its distance to the cell's top-left corner and grows with it: its edges move
        // with the cell's size only.
        let growth = RectComponents(width: velocity.width, height: velocity.height)
        let start = sublayerFrames(chromeFrames(cellSize: from.size)), rest = sublayerFrames(chromeFrames(cellSize: bounds.size))
        for ((sublayer, startFrame), (_, restFrame)) in zip(start, rest) where startFrame != restFrame {
            moves += Self.springMoves(sublayer, from: startFrame, to: restFrame, velocity: growth)
        }
        releaseGlowOutline()
        return moves
    }

    /// The host's spring landed (or was taken back to the CPU): the glow's outline comes back at rest.
    func rideEnded() {
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
        rideEnded()
    }

    /// Scalar springs of `layer`'s position and size from the frame `from` to `to` (its superlayer's
    /// coordinates, an identity transform; `to` is its model frame already), the frame changing at
    /// `velocity`.
    static func springMoves(_ layer: CALayer, from: CGRect, to: CGRect, velocity: RectComponents) -> [RenderSpring.Move] {
        let anchor = layer.anchorPoint
        let start = RenderLayerAxes.position(of: from, anchor: anchor), rest = RenderLayerAxes.position(of: to, anchor: anchor)
        let rate = RenderLayerAxes(x: 1, y: 1).velocity(velocity, anchor: anchor)
        return [
            RenderSpring.Move(layer, "position.x", from: start.x, to: rest.x, velocity: rate.position.x),
            RenderSpring.Move(layer, "position.y", from: start.y, to: rest.y, velocity: rate.position.y),
            RenderSpring.Move(layer, "bounds.size.width", from: from.width, to: to.width, velocity: rate.size.width),
            RenderSpring.Move(layer, "bounds.size.height", from: from.height, to: to.height, velocity: rate.size.height),
        ]
    }
}
