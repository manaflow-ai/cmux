import AppKit
import CmuxNextDesign
import QuartzCore

/// A new dock column on the render server (chrome-parity p03-rendering-028, on with `motion.renderServer`):
/// the docked pane grows in from its screen edge on its host's render-server spring
/// (``springSplitOnRenderServer()``), and the strip's clip, the strip container's bounds
/// (p03-rendering-023), springs with it on the same token. The main thread steps no frame for it: no
/// per-frame `PaneArrival.stripClip`, no MotionClock frame.
extension ScreenContentView {
    /// A change on the render server whose docks still showed short of their rest (a new dock column at
    /// its screen edge, a dock springing to a new width): the strip container takes its rest range in
    /// this turn, the strip's range beside the docks at rest (`PaneArrival.stripClip`, computed here, at
    /// plan apply, and never per frame), and Core Animation springs its layer's position and bounds from
    /// `start` (the range beside the docks where they showed) on `spring`, the panes' token. Bounds origin
    /// and position spring together, so the clip edge moves with the growing dock while the strip's hosts,
    /// whose frames are in this view's coordinates, show only their own springs. Chrome animates a clip
    /// rect on the compositor the same way: a clip node's bounds, not a mask per layer
    /// (`cc/trees/clip_node.h`). `landed` runs once, at the landing or now when nothing springs.
    /// Returns whether the container springs.
    @discardableResult
    func springStripContainer(from start: CGRect?, on spring: RenderSpring,
                              landed: @escaping @MainActor @Sendable () -> Void) -> Bool { // perf-hot: 4ms motion-frame
        guard let start, !isCanvas, !liftsStripContainer, let rest = PaneArrival.stripClip(geometry, docks: []), start != rest,
              let layer = stripContainer.layer else {
            landed()
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer's values for the start range are read from the model, then the rest range is set once.
        stripContainer.place(range: start, liftedTo: nil)
        let position = layer.position, shown = layer.bounds
        stripContainer.place(range: rest, liftedTo: nil)
        spring.animateGroup([
            RenderSpring.Move(layer, "position", from: position, to: layer.position),
            RenderSpring.Move(layer, "bounds", from: shown, to: layer.bounds),
        ], in: stripContainer) { _ in landed() }
        CATransaction.commit()
        // Pages drawing in their own windows re-read their clip shapes, which carry this range.
        context.stripClipsDidChange()
        return true
    }

    /// Stops the strip container's render-server spring (``springStripContainer(from:on:landed:)``): it shows
    /// its model range now, which the CPU's next presentation places.
    func stopStripContainerSpring() {
        guard let layer = stripContainer.layer else { return }
        RenderSpring.stop(layer, "position")
        RenderSpring.stop(layer, "bounds")
    }
}
