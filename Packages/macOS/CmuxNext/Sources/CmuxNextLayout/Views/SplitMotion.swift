import CmuxNextDesign
import CoreGraphics

/// The physics of a split (DESIGN P3, P4; plans/cmux-next/motion.md). Cmd-D,
/// Cmd-Shift-D, closing a split and a released divider move every pane edge
/// and divider of the change on the `move` spring, all started together from
/// rest (or from one shared release velocity, `seed`). The spring equation
/// is linear, so each coordinate then covers the same fraction of its travel
/// at every instant: the frames are one spring on the divider fraction, read
/// through each pane's start and end. The new pane grows from the split edge
/// while the other shrinks, and the divider moves once.
///
/// Content moves with it (Lawrence 2026-10-18: "content must move while it animates"): every
/// pane is laid out live at the rect its spring presents on every display frame, its tab strip,
/// terminal and page included, as a macOS live window resize is. Nothing holds a final-size
/// layout under a clip, so nothing jumps when the spring ends.
struct SplitMotion {
    /// A divider released while moving at `velocity` (pt/s along `axis`):
    /// the spring toward the snapped layout starts with that velocity. In
    /// the spring's own unit (the fraction of the travel left) the divider's
    /// velocity is `velocity / travel`; every moving pane and divider gets
    /// the same fraction, so the whole change stays one spring. A release
    /// moving away from the target, or with nothing left to travel, starts
    /// from rest.
    static func seed(velocity: CGFloat, along axis: SplitAxis, divider: AnimatedFrame,
                     panes: inout [PaneID: AnimatedFrame], dividers: inout [DividerHandleView.Kind: AnimatedFrame]) {
        let travel = axis == .horizontal ? divider.x.target - divider.x.value : divider.y.target - divider.y.value
        guard abs(travel) > 0.5 else { return }
        let fraction = velocity / travel
        guard fraction > 0 else { return }
        // A fling faster than the spring could start (10 travels a second) is capped there.
        let rate = min(fraction, 10)
        for key in Array(panes.keys) { panes[key]?.seed(fractionVelocity: rate) }
        for key in Array(dividers.keys) { dividers[key]?.seed(fractionVelocity: rate) }
    }
}

extension SplitMotion {
    /// Where a new divider at `divider` (its target) starts, as a shift from there: by as much as
    /// the edge of an existing pane beside it (not one in `skipping`, the panes the change adds)
    /// still has to travel, so the divider rides that edge from its first frame. Nil without one.
    static func startShift(of divider: CGRect, axis: SplitAxis, panes: [PaneID: AnimatedFrame], skipping: Set<PaneID>) -> CGVector? {
        let reach: CGFloat = 16
        for (pane, frame) in panes where !skipping.contains(pane) {
            let target = frame.targetRect, shown = frame.rect
            if axis == .horizontal {
                guard min(target.maxY, divider.maxY) - max(target.minY, divider.minY) > 1 else { continue }
                if abs(target.maxX - divider.midX) <= reach { return CGVector(dx: shown.maxX - target.maxX, dy: 0) }
                if abs(target.minX - divider.midX) <= reach { return CGVector(dx: shown.minX - target.minX, dy: 0) }
            } else {
                guard min(target.maxX, divider.maxX) - max(target.minX, divider.minX) > 1 else { continue }
                if abs(target.maxY - divider.midY) <= reach { return CGVector(dx: 0, dy: shown.maxY - target.maxY) }
                if abs(target.minY - divider.midY) <= reach { return CGVector(dx: 0, dy: shown.minY - target.minY) }
            }
        }
        return nil
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
