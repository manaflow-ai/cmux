#if os(iOS)
import CoreGraphics

/// The push measure (DEBUG): a frame in which everything drawn jumped, read from how far the rows
/// moved on screen per committed frame, NOT less what the scroll or the list explains. The shift
/// measures subtract the list's own moves (its slide, its jump to the newest row) as explained, so a
/// one-frame jump the list makes on purpose reads 0 there while the screen visibly jumps (a `.down`
/// list following its top under a flood of arrivals: video 8c0c85fb at 4614ff6b, frames 483-640, moves
/// of 86-200 pt in single frames between slide steps of 6-34 pt, frame shift 0.0 in the same run).
/// Smooth motion (a drag, a fling, the slide) changes by a few points a frame; a push differs from
/// both the frame before and the frame after.
enum PagedListPush {
    /// How far a frame's move may differ from both neighbours' before it is a push (pt). The video's
    /// smooth phases differ by under 8 pt at p90 (4 px at 201 px wide); its pushes by 66 pt and more.
    static let threshold: CGFloat = 24

    /// Frame `move`'s push size: how far it differs from the nearer of `before` and `after`, when it
    /// differs from both by more than ``threshold``; else 0.
    static func size(before: CGFloat, move: CGFloat, after: CGFloat) -> CGFloat {
        let nearer = min(abs(move - before), abs(move - after))
        return nearer > threshold ? nearer : 0
    }

    /// One committed frame as the push measure sees it.
    struct Frame {
        /// The followed row's raw drawn move in this frame (pt).
        var move: CGFloat
        /// A finger was on the list.
        var tracking = false
        /// The person asked for this jump (the newest-rows indicator's jump with motion off, a jump to
        /// the newest row): the list moves everything at once on purpose.
        var deliberate = false
    }

    enum Verdict: Equatable {
        /// Smooth, or a jump the person asked for.
        case none
        /// Everything drawn jumped in one frame, with no finger down (asserted).
        case push(CGFloat)
        /// The same under a finger: recorded, not asserted, until the drag threshold is known (the
        /// test driver's synthetic drags move in steps; their size comes from these records).
        case drag(CGFloat)
    }

    /// The middle frame's verdict, judged against the frames on both sides.
    static func verdict(before: Frame, middle: Frame, after: Frame) -> Verdict {
        guard !middle.deliberate else { return .none }
        let size = size(before: before.move, move: middle.move, after: after.move)
        guard size > 0 else { return .none }
        return middle.tracking ? .drag(size) : .push(size)
    }
}
#endif
