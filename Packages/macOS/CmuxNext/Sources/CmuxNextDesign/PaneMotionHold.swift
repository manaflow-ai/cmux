public import AppKit

/// A pane's content held through a layout spring, as a value (FRAME OWNER REFACTOR S1): the edges the held content rides.
/// The pane hands it down its view tree. Every in-process container (the tab strip, the content area) follows the pane's
/// rect in each frame and hands the hold on; only what draws its pixels on another thread or in another process (a
/// terminal surface, a page) keeps its start size, on these edges, and lays out once when the hold ends.
public nonisolated struct PaneMotionHold: Equatable, Sendable {
    /// The held content's trailing edge rides the pane's trailing edge (false: its leading edge rides the leading one).
    public var trailing: Bool
    /// Its bottom edge rides the pane's bottom edge (false: its top edge rides the top one).
    public var bottom: Bool

    public init(trailing: Bool, bottom: Bool) {
        self.trailing = trailing
        self.bottom = bottom
    }

    /// The bounds origin of a container that is not flipped, `size` big, whose subviews keep the frames they had when it
    /// was `held` big: they show on these edges, cut where the container is smaller.
    public func boundsOrigin(holding held: CGSize, in size: CGSize) -> CGPoint {
        CGPoint(x: trailing ? held.width - size.width : 0, y: bottom ? 0 : held.height - size.height)
    }
}

/// Pane content whose chrome follows the pane in every frame of a hold (FRAME OWNER REFACTOR S1): its tab strip lays out
/// at the pane's rect in the frame's tick, and only its content area holds. A nil area: the pane holds the whole view,
/// its chrome included.
@MainActor
public protocol PaneMotionHolding: NSView {
    /// The area that holds while the pane's chrome follows, or nil to be held whole.
    var paneMotionHoldArea: PaneContentAreaView? { get }
}
