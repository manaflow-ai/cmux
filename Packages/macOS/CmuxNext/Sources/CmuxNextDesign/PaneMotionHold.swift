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
/// toolbar and scroller cover the pane. Its producer (the terminal surface, the page: pixels drawn on another thread or
/// in another process) keeps its size on the hold's edges and lays out once when the hold ends; a terminal's surface
/// follows the area too (cmux-ad m6, m18: each size shows with its frame, or, late, the last frame top-left in the new
/// bounds for a commit).
@MainActor
public protocol PaneMotionHoldFollowing: NSView {
    /// Whether it follows now (a page kind that cannot hold its pixels yet is held whole, as in S1).
    var followsPaneMotion: Bool { get }
    /// The area holds on `hold`'s edges, from an area `heldSize` big when the hold began (the size the view had then);
    /// nil, nil: the hold ended, and the view's frame is the area's again. Called once per change, never per frame.
    func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?)
    /// Draw ahead (cmux-ad m26): the pane's spring gives this follower `nextHostSize` at the next refresh. A producer that
    /// draws on another thread asks for that size now, after this refresh's commit, so its frame is ready when the refresh
    /// shows it. Called once per spring frame, only on followers of a hold.
    func drawAhead(nextHostSize: CGSize)
    /// Draw ahead of the hold's first frame (T-KEYS 3): a key press's spring gives this follower `nextHostSize` at its
    /// first refresh, the refresh whose layout hands it the hold. A producer that draws on another thread asks for that
    /// size in the key's turn, so the frame that shows the press is ready. Called once per press, in the key's turn, on
    /// the followers the hold will hand. `keyPress`: false for a snapped structural change (split, close, zoom with Reduce
    /// Motion or pane animations off, ``ScreenContentView`` `holdsSnapForContent`), which asks the size render only; a key
    /// press's size also takes its grid to the program (RESIZE P0 11).
    func drawAheadOfFollow(nextHostSize: CGSize, keyPress: Bool)
    /// A snapped change this follower's size was drawn ahead for showed (``ScreenContentView`` `presentHeldSnap`, RESIZE
    /// P0 14): a size drawn ahead that the change's placement did not take goes now. Until then only a placement at a new
    /// size may take it or drop it.
    func aheadOfFollowShown()
    /// Whether a key press's snap must keep waiting before it shows this follower's size drawn ahead
    /// (``drawAheadOfFollow(nextHostSize:keyPress:)`` with `keyPress`; Reduce Motion, RESIZE P0 20): its producer asked
    /// the program to redraw at the new size and has no frame of that redraw yet. `refreshesWaited`: the frame ticks the
    /// snap waited so far, counting the one asking (1 at the first). The follower bounds its own wait: false once it
    /// waited as long as it may.
    func aheadOfFollowAwaitsContent(refreshesWaited: Int) -> Bool
}

public extension PaneMotionHoldFollowing {
    var followsPaneMotion: Bool { true }
    func drawAhead(nextHostSize: CGSize) {}
    func drawAheadOfFollow(nextHostSize: CGSize, keyPress: Bool) {}
    func aheadOfFollowShown() {}
    func aheadOfFollowAwaitsContent(refreshesWaited: Int) -> Bool { false }
}
