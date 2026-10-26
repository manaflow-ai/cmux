import AppKit
import CmuxNextDesign
import QuartzCore

/// A pane's chrome (ring, glow, border, dim) springing with its host on the render server
/// (p03-rendering-022a): its own layer from the host's offset off rest, and every sublayer from its frame
/// at the starting cell size to its rest frame (`PaneMotionPlan.ChromeFrames`), all on the host's token
/// from the host's begin time, so nothing rides `autoresizingMask` and the ring stays on the pane.
extension PaneOverlayView {
    /// Seconds ahead the sublayers' starting velocity is read at: their frames are piecewise linear in the cell size.
    private static let velocityStep: CGFloat = 1.0 / 1000

    /// Puts the chrome at `rest` (its superview's coordinates) now and springs it there as `spring` says.
    func springOnRenderServer(to rest: CGRect, _ spring: PaneChromeSpring) {
        if frame != rest { frame = rest }
        guard let layer, let superview else { return }
        var moves = layer.springMoves(offset: spring.offset, velocity: spring.velocity, flipsY: superview.layerFlipsY)
        let start = Self.size(rest.size, plus: spring.offset, times: 1)
        let ahead = Self.size(start, plus: spring.velocity, times: Self.velocityStep)
        let rests = sublayerFrames(chromeFrames(cellSize: rest.size))
        let starts = sublayerFrames(chromeFrames(cellSize: start)), later = sublayerFrames(chromeFrames(cellSize: ahead))
        for index in rests.indices {
            let from = starts[index].frame
            // The sublayers are placed in this view's (flipped) coordinates, as `layoutLayers` places them.
            moves += rests[index].layer.springMoves(offset: FrameDelta(from: from, to: rests[index].frame),
                                                    velocity: FrameDelta(from: later[index].frame, to: from).scaled(by: 1 / Self.velocityStep),
                                                    flipsY: false)
        }
        spring.spring.animateGroup(moves, in: self, startingAt: spring.begin)
    }

    /// Takes the render-server springs off the chrome and its sublayers: each shows its model frame now.
    func stopRenderSprings() {
        guard let layer else { return }
        let targets = [layer] + sublayerFrames(chromeFrames(cellSize: bounds.size)).map { $0.layer }
        for target in targets {
            for keyPath in PaneHostView.renderSpringKeyPaths { RenderSpring.stop(target, keyPath) }
        }
    }

    private static func size(_ size: CGSize, plus delta: FrameDelta, times factor: CGFloat) -> CGSize {
        CGSize(width: max(0, size.width + delta.width * factor), height: max(0, size.height + delta.height * factor))
    }
}
