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

    /// Where a producer `size` big sits on these edges of `area`, in a view that is not flipped (FRAME OWNER S3): its
    /// edge on the side that does not move stays put, and the moving edge of a growing pane uncovers it.
    public func producerFrame(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: trailing ? area.maxX - size.width : area.minX, y: bottom ? area.minY : area.maxY - size.height,
               width: size.width, height: size.height)
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

/// A container in a pane's content area that follows the area in every frame of a hold (FRAME OWNER REFACTOR S3: a
/// terminal's host, a browser's chrome). The area gives it its own bounds in each frame, so its background, padding,
/// toolbar and scroller cover the pane; only its producer (the terminal surface, the page: pixels drawn on another
/// thread or in another process) keeps its size, on the hold's edges, and lays out once when the hold ends.
@MainActor
public protocol PaneMotionHoldFollowing: NSView {
    /// Whether it follows now (a page kind that cannot hold its pixels yet is held whole, as in S1).
    var followsPaneMotion: Bool { get }
    /// The area holds on `hold`'s edges, from an area `heldSize` big when the hold began (the size the view had then);
    /// nil, nil: the hold ended, and the view's frame is the area's again. Called once per change, never per frame.
    func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?)
}

public extension PaneMotionHoldFollowing {
    var followsPaneMotion: Bool { true }
}
