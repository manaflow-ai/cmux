import CmuxNextDesign
import CoreGraphics

/// The physics of a divider's release (plans/cmux-next/motion.md). A divider released while it moves starts the spring
/// toward the layout its release made from one shared release velocity (`seed`). The spring equation is linear, so each
/// coordinate then covers the same fraction of its travel at every instant: the frames are one spring on the divider
/// fraction, read through each pane's start and end.
///
/// A split, a close, a zoom and an unzoom have no physics: each is one commit, shown whole in one frame
/// (`ScreenContentView.reconcile`, `ScreenContentView+SnapFrame`).
struct SplitMotion {
    /// A divider released while moving at `velocity` (pt/s along `axis`):
    /// the spring toward the snapped layout starts with that velocity. In
    /// the spring's own unit (the fraction of the travel left) the divider's
    /// velocity is `velocity / travel`; every moving pane and divider gets
    /// the same fraction, so the whole change stays one spring. A release
    /// moving away from the target, or with nothing left to travel, starts
    /// from rest.
    /// `moved` / `movedDividers`: the frames the release's layout change retargeted; a frame already on its way
    /// for another reason keeps its own velocity. Nil: every frame (callers that know no better).
    /// `edges` (FRAME OWNER S2B, the drag's `DividerDragState.sharedEdges`): only the edges each frame's
    /// target moved get the release's velocity; an edge that did not move keeps its own spring's (`SharedEdgeMotion`).
    static func seed(velocity: CGFloat, along axis: SplitAxis, divider: AnimatedFrame,
                     panes: inout [PaneID: AnimatedFrame], dividers: inout [DividerHandleView.Kind: AnimatedFrame],
                     moved: Set<PaneID>? = nil, movedDividers: Set<DividerHandleView.Kind>? = nil,
                     edges: (panes: [PaneID: CGRect], dividers: [DividerHandleView.Kind: CGRect])? = nil) {
        let travel = axis == .horizontal ? divider.x.target - divider.x.value : divider.y.target - divider.y.value
        guard abs(travel) > 0.5 else { return }
        let fraction = velocity / travel
        guard fraction > 0 else { return }
        // A fling faster than 10 travels a second is capped there. That is under the limit of every pane token (omega,
        // 20 a second or more at speed normal), so no edge starts faster than it can stop on its place; the frames
        // apply that limit at each step whatever a caller wrote (`SpringParameters.admitted`).
        let rate = min(fraction, 10)
        if let edges {
            for (key, frame) in panes where moved?.contains(key) ?? true {
                var seeded = frame
                SharedEdgeMotion.seed(&seeded, moved: .init(before: edges.panes[key], after: frame.targetRect), rate: rate)
                panes[key] = seeded
            }
            for (key, frame) in dividers where movedDividers?.contains(key) ?? true {
                var seeded = frame
                SharedEdgeMotion.seed(&seeded, moved: .init(before: edges.dividers[key], after: frame.targetRect), rate: rate)
                dividers[key] = seeded
            }
            return
        }
        for key in Array(panes.keys) where moved?.contains(key) ?? true { panes[key]?.seed(fractionVelocity: rate) }
        for key in Array(dividers.keys) where movedDividers?.contains(key) ?? true { dividers[key]?.seed(fractionVelocity: rate) }
    }
}

extension AnimatedFrame {
    /// Gives every component still short of its target the velocity of
    /// `rate` (fractions of its remaining travel per second).
    mutating func seed(fractionVelocity rate: CGFloat) {
        x.velocity = (x.target - x.value) * rate
        y.velocity = (y.target - y.value) * rate
        width.velocity = (width.target - width.value) * rate
        height.velocity = (height.target - height.value) * rate
    }
}
