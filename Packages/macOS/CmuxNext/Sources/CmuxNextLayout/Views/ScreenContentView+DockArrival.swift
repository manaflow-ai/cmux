import AppKit
import CmuxNextDesign
import QuartzCore

/// A new dock column on the render server (on with `motion.renderServer`):
/// the docked pane grows in from its screen edge on its host's render-server spring
/// (``springSplitOnRenderServer()``), and the strip's clip, the strip container's bounds,
/// springs with it on the same token. The main thread steps no frame for it: no
/// per-frame `PaneArrival.stripClip` (``stripRangesComputed``), no MotionClock frame.
extension ScreenContentView {
    /// The strip's range in `geometry` beside the docks where `docks` (still growing in) show
    /// (`PaneArrival.stripClip`), counted in ``stripRangesComputed``: a plan's apply computes it, and so does
    /// each frame of a dock the CPU steps; a dock on the render server computes none per frame.
    func stripRange(in geometry: ScreenGeometry, beside docks: [AnimatedFrame]) -> CGRect? {
        stripRangesComputed += 1
        return PaneArrival.stripClip(geometry, docks: docks)
    }

    /// A change on the render server whose docks still showed short of their rest (a new dock column at
    /// its screen edge, a dock springing to a new width): the strip container takes its rest range in
    /// this turn (``restStripRange``), and Core Animation springs its layer's position and bounds from
    /// `start` (the range beside the docks where they showed), at `velocity` (the range's, the docks' inner
    /// edges' speed, `PaneArrival.stripClipVelocity`), on `spring`, the panes' token. One scalar spring per
    /// component, as a pane host's (``NSView/renderSpringMoves(from:velocity:)``), so a change that takes the
    /// springs back mid-growth restarts the clip at the dock's speed and the two edges stay together. Bounds
    /// origin and position spring together, so the clip edge moves with the growing dock while the strip's
    /// hosts, whose frames are in this view's coordinates, show only their own springs. Chrome animates a clip
    /// rect on the compositor the same way: a clip node's bounds, not a mask per layer
    /// (`cc/trees/clip_node.h`). `landed` runs once, at the landing or now when nothing springs.
    /// Returns whether the container springs.
    @discardableResult
    func springStripContainer(from start: CGRect?, velocity: RectComponents, on spring: RenderSpring,
                              landed: @escaping @MainActor @Sendable () -> Void) -> Bool { // perf-hot: 4ms motion-frame
        guard let start, !isCanvas, !liftsStripContainer, let rest = restStripRange, start != rest || !velocity.isZero,
              let layer = stripContainer.layer, let superview = stripContainer.superview else {
            landed()
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer's values for the start range are read from the model, then the rest range is set once.
        stripContainer.place(range: start, liftedTo: nil)
        let position = layer.position, shown = layer.bounds
        stripContainer.place(range: rest, liftedTo: nil)
        let to = layer.position, bounds = layer.bounds
        // The range's velocity on the layer's axes: its position in the screen's layer, its bounds in its own.
        let moving = RenderLayerAxes(superview).velocity(velocity, anchor: layer.anchorPoint).position
        let inner = RenderLayerAxes(stripContainer).velocity(velocity, anchor: .zero)
        spring.animateGroup([
            RenderSpring.Move(layer, .positionX, from: position.x, to: to.x, velocity: moving.x),
            RenderSpring.Move(layer, .positionY, from: position.y, to: to.y, velocity: moving.y),
            RenderSpring.Move(layer, .boundsOriginX, from: shown.origin.x, to: bounds.origin.x, velocity: inner.position.x),
            RenderSpring.Move(layer, .boundsOriginY, from: shown.origin.y, to: bounds.origin.y, velocity: inner.position.y),
            RenderSpring.Move(layer, .boundsWidth, from: shown.width, to: bounds.width, velocity: inner.size.width),
            RenderSpring.Move(layer, .boundsHeight, from: shown.height, to: bounds.height, velocity: inner.size.height),
        ], in: stripContainer) { _ in landed() }
        CATransaction.commit()
        // Pages drawing in their own windows re-read their clip shapes, which carry this range.
        context.stripClipsDidChange()
        return true
    }

    /// Stops the strip container's render-server spring (``springStripContainer(from:velocity:on:landed:)``):
    /// it shows its model range now, which the CPU's next presentation places.
    func stopStripContainerSpring() {
        guard let layer = stripContainer.layer else { return }
        RenderSpring.stop(layer, "position")
        RenderSpring.stop(layer, "bounds")
    }
}
