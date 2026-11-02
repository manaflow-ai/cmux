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
    /// `moved` / `movedDividers`: the frames the release's layout change retargeted; a frame already on its way
    /// for another reason keeps its own velocity. Nil: every frame (callers that know no better).
    static func seed(velocity: CGFloat, along axis: SplitAxis, divider: AnimatedFrame,
                     panes: inout [PaneID: AnimatedFrame], dividers: inout [DividerHandleView.Kind: AnimatedFrame],
                     moved: Set<PaneID>? = nil, movedDividers: Set<DividerHandleView.Kind>? = nil) {
        let travel = axis == .horizontal ? divider.x.target - divider.x.value : divider.y.target - divider.y.value
        guard abs(travel) > 0.5 else { return }
        let fraction = velocity / travel
        guard fraction > 0 else { return }
        // A fling faster than the spring could start (10 travels a second) is capped there.
        let rate = min(fraction, 10)
        for key in Array(panes.keys) where moved?.contains(key) ?? true { panes[key]?.seed(fractionVelocity: rate) }
        for key in Array(dividers.keys) where movedDividers?.contains(key) ?? true { dividers[key]?.seed(fractionVelocity: rate) }
    }
}

extension SplitMotion {
    /// Where a new divider at `divider` (its target) starts, as a shift from there, and the
    /// velocity it starts with along `axis`: where the edge of an existing pane beside it (not one
    /// in `skipping`, the panes the change adds) shows now and how fast that edge moves, so the
    /// divider rides that edge from its first frame, even when a split lands while the panes still
    /// move (rapid Cmd-D). Nil without one.
    /// `beside` is that pane's frame: the divider takes its shown place across its axis too (``follow``), so a
    /// split of a pane still moving sideways puts the divider under it, not at its column's rest.
    static func startShift(of divider: CGRect, axis: SplitAxis, panes: [PaneID: AnimatedFrame],
                           skipping: Set<PaneID>) -> (shift: CGVector, velocity: CGFloat, beside: AnimatedFrame)? {
        let reach: CGFloat = 16
        for (pane, frame) in panes where !skipping.contains(pane) {
            let target = frame.targetRect, shown = frame.rect
            if axis == .horizontal {
                guard min(target.maxY, divider.maxY) - max(target.minY, divider.minY) > 1 else { continue }
                if abs(target.maxX - divider.midX) <= reach {
                    return (CGVector(dx: shown.maxX - target.maxX, dy: 0), frame.x.velocity + frame.width.velocity, frame)
                }
                if abs(target.minX - divider.midX) <= reach { return (CGVector(dx: shown.minX - target.minX, dy: 0), frame.x.velocity, frame) }
            } else {
                guard min(target.maxX, divider.maxX) - max(target.minX, divider.minX) > 1 else { continue }
                if abs(target.maxY - divider.midY) <= reach {
                    return (CGVector(dx: 0, dy: shown.maxY - target.maxY), frame.y.velocity + frame.height.velocity, frame)
                }
                if abs(target.minY - divider.midY) <= reach { return (CGVector(dx: 0, dy: shown.minY - target.minY), frame.y.velocity, frame) }
            }
        }
        return nil
    }

    /// A new pane's sliver (`PaneArrival.seed`, zero wide or zero tall) rides the edge it opens
    /// from: `panes` are the frames before this change's targets (their old targets and what they
    /// show), and the sliver moves by as much as that edge still had to travel and starts at its
    /// velocity. At rest that changes nothing; a split landing while the row still moves (the next
    /// Cmd-D) keeps the gap beside the new pane exact from its first frame instead of letting the
    /// sliver lag the moving edge.
    /// Across the split's axis it takes the shown place of the pane whose edge it rides: a split of a pane that is
    /// still moving sideways (a column growing in, then split down) starts under that pane, at its shown x and width
    /// and with its velocity, not at its column's rest (RESIZE VIDEOS O1: 31 pt off for 12 frames).
    static func ride(_ frame: inout AnimatedFrame, panes: [PaneID: AnimatedFrame], skipping: Set<PaneID>) {
        let seed = frame.rect
        let horizontal: Bool
        if seed.width == 0 { horizontal = true } else if seed.height == 0 { horizontal = false } else { return }
        let reach: CGFloat = 16
        var best: (distance: CGFloat, shift: CGFloat, velocity: CGFloat, beside: AnimatedFrame)?
        // The cross axis follows the nearest edge whose pane shares the new pane's cross-axis targets (the pane the
        // split gave space from), not a neighbour that only touches the same line.
        var crossBeside: (distance: CGFloat, frame: AnimatedFrame)?
        func consider(_ distance: CGFloat, _ shift: CGFloat, _ velocity: CGFloat, _ beside: AnimatedFrame) {
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (distance, shift, velocity, beside) }
            let sameCross = horizontal
                ? abs(beside.y.target - seed.minY) < 0.5 && abs(beside.height.target - seed.height) < 0.5
                : abs(beside.x.target - seed.minX) < 0.5 && abs(beside.width.target - seed.width) < 0.5
            if distance <= reach, sameCross, distance < (crossBeside?.distance ?? .infinity) { crossBeside = (distance, beside) }
        }
        for (pane, other) in panes where !skipping.contains(pane) {
            let target = other.targetRect, shown = other.rect
            if horizontal {
                guard min(target.maxY, seed.maxY) - max(target.minY, seed.minY) > 1 else { continue }
                consider(abs(target.maxX - seed.minX), shown.maxX - target.maxX, other.x.velocity + other.width.velocity, other)
                consider(abs(target.minX - seed.minX), shown.minX - target.minX, other.x.velocity, other)
            } else {
                guard min(target.maxX, seed.maxX) - max(target.minX, seed.minX) > 1 else { continue }
                consider(abs(target.maxY - seed.minY), shown.maxY - target.maxY, other.y.velocity + other.height.velocity, other)
                consider(abs(target.minY - seed.minY), shown.minY - target.minY, other.y.velocity, other)
            }
        }
        if let cross = crossBeside?.frame {
            if horizontal { follow(&frame.y, &frame.height, beside: cross.y, cross.height) } else { follow(&frame.x, &frame.width, beside: cross.x, cross.width) }
        }
        guard let best else { return }
        if horizontal {
            frame.x.value += best.shift
            frame.x.target = frame.x.value
            frame.x.velocity = best.velocity
        } else {
            frame.y.value += best.shift
            frame.y.target = frame.y.value
            frame.y.velocity = best.velocity
        }
    }

    /// The cross-axis start of a new pane or divider (`origin` and `length` at their targets) beside a frame whose
    /// cross axis is `besideOrigin`/`besideLength`: where that frame shows, with its velocities, so the two move as
    /// one. Only for a frame with the same cross-axis targets (the pane the split gave space from, in its column or
    /// row): a neighbour that only touches the edge (a full-height pane beside a column whose panes move up and down)
    /// leaves the cross axis at rest.
    static func follow(_ origin: inout SpringValue, _ length: inout SpringValue, beside besideOrigin: SpringValue, _ besideLength: SpringValue) {
        guard abs(origin.target - besideOrigin.target) < 0.5, abs(length.target - besideLength.target) < 0.5 else { return }
        origin.value = origin.target + (besideOrigin.value - besideOrigin.target)
        origin.velocity = besideOrigin.velocity
        length.value = length.target + (besideLength.value - besideLength.target)
        length.velocity = besideLength.velocity
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
