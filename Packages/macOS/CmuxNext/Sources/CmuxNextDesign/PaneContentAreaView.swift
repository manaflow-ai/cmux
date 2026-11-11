public import AppKit
import QuartzCore

/// A pane's content area, under its tab strip: the one rounded container its terminal, page or chat shows in. It clips
/// to its bounds.
///
/// While ``hold`` is set (FRAME OWNER REFACTOR S1, a keyboard resize), the area's frame follows the pane in every frame
/// and its subviews do not: they keep the frames they had when the hold began, and the bounds origin shows them on the
/// hold's edges (as NSClipView scrolls its document), cut by the area where it is smaller and over its background where
/// it is larger. Nothing in them lays out or resizes during the hold. When it ends they take the area's size once,
/// before anything hears that the motion ended.
///
/// A container in it (``PaneMotionHoldFollowing``: a terminal's host, a browser's chrome; FRAME OWNER S3) takes the
/// area's bounds in every frame instead and hears the hold once, so its own ground covers the pane; only its producer
/// keeps its size (a terminal's surface follows too, cmux-ad m6 and m18).
public final class PaneContentAreaView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The edges the held subviews ride; nil at rest. Setting nil lets them go at once (``release(from:)``).
    public var hold: PaneMotionHold? {
        didSet {
            guard hold != oldValue else { return }
            if hold != nil, heldSize == nil { heldSize = bounds.size }
            if hold == nil, let held = heldSize { release(from: held) } else { showHeld(handing: true) }
        }
    }

    /// The ground the area shows under its content: its pane's (the window's color where panes paint it), else none.
    public var restingGround: CGColor? { didSet { paintGround() } }

    /// The ground of content that comes next but is not made yet (SPLIT NEW PANE GROUND, m81: a split's stand-in terminal
    /// waits for its surface until after its key's frame): it shows instead of ``restingGround`` until then, so the new
    /// pane has its terminal's ground from the key's frame, never the window's color.
    public var waitingGround: CGColor? { didSet { paintGround() } }

    private func paintGround() {
        let ground = waitingGround ?? restingGround
        if layer?.backgroundColor != ground { layer?.backgroundColor = ground }
    }

    /// The area's size when the hold began: the size its subviews keep; nil at rest.
    private var heldSize: CGSize?

    /// Whether the subviews are held now.
    public var isHolding: Bool { heldSize != nil }

    /// The rect a view that fills the area takes: its bounds at rest; while it holds, the held content's rect, so a view
    /// that joins mid-hold (a tab switch) is held with the rest and its pane's rest-size change applies to it too.
    public var contentBounds: CGRect { heldSize.map { CGRect(origin: .zero, size: $0) } ?? bounds }

    /// The rect `view` takes when it fills the area: ``contentBounds``, or the area's bounds for a container that already
    /// follows the pane through this hold (switched away and back). A container that joins comes in at the held rect, so
    /// what it measures on its way in (a terminal's rest size) is from the held size.
    public func contentBounds(for view: NSView) -> CGRect { handed.contains(ObjectIdentifier(view)) ? bounds : contentBounds }

    /// The containers handed this hold (``PaneMotionHoldFollowing``), which follow the area until it ends: one shown or added
    /// during the hold hears it in its first frame; one whose producer stops holding (a page whose DevTools docked) keeps
    /// following and lays its producer out live.
    private var handed: Set<ObjectIdentifier> = []

    /// A hold ended since the last call: the owner runs, once, the work it left alone during the hold.
    public func takeEndedHold() -> Bool {
        defer { endedHold = false }
        return endedHold
    }

    private var endedHold = false

    public override func setFrameSize(_ newSize: NSSize) { // perf-hot: 4ms motion-frame
        super.setFrameSize(newSize)
        showHeld(handing: false)
    }

    /// Held subviews keep their frames: no autoresizing while the area holds.
    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard heldSize == nil else { return }
        super.resizeSubviews(withOldSize: oldSize)
    }

    /// Rounds the area's corners (0: square), with no implicit animation.
    public func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }

    /// The held subviews on the hold's edges of the area's size now: one bounds write, no subview frame changes; each
    /// following container takes the area's bounds (one frame write). `handing`: the hold changed, the followers hear it.
    private func showHeld(handing: Bool) { // perf-hot: 4ms motion-frame
        guard let heldSize, let hold else { return }
        let origin = hold.boundsOrigin(holding: heldSize, in: bounds.size)
        if bounds.origin != origin { setBoundsOrigin(origin) }
        for case let follower as any PaneMotionHoldFollowing in subviews {
            let id = ObjectIdentifier(follower)
            if !handed.contains(id) {
                // A container joins once, when it is shown and can hold (a hidden one, a parked tab, stays held).
                guard follows(follower) else { continue }
                handed.insert(id)
                follower.followPaneMotion(hold, heldSize: heldSize)
            } else if handing {
                follower.followPaneMotion(hold, heldSize: heldSize)
            }
            // A hidden one (parked) takes the area's bounds when it shows again (`followerDidShow`).
            if !follower.isHidden, follower.frame != bounds {
                follower.frame = bounds
                follower.needsLayout = true // its ground, toolbar and producer placement, in this frame's layout pass
            }
        }
    }

    /// Draw ahead (cmux-ad m26): the area will be `sizeChange` larger (negative: smaller) at the next refresh of its pane's
    /// spring; each shown follower hears its size then (it follows the area's bounds).
    public func drawAhead(sizeChange: CGSize) { // perf-hot: 1ms motion-frame
        guard hold != nil, sizeChange != .zero else { return }
        let next = CGSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        for case let follower as any PaneMotionHoldFollowing in subviews where !follower.isHidden && handed.contains(ObjectIdentifier(follower)) {
            follower.drawAhead(nextHostSize: next)
        }
    }

    /// Draw ahead of a key hold's first frame (T-KEYS 3): the area will be `sizeChange` larger (negative: smaller) at the
    /// first refresh of its pane's spring, whose layout begins the hold. Each follower that hold will hand hears its size
    /// then, in the key's turn, as ``drawAhead(sizeChange:)`` tells it each later refresh's. `keyPress`: false for a
    /// snapped structural change (``PaneMotionHoldFollowing/drawAheadOfFollow(nextHostSize:keyPress:)``).
    public func drawAheadOfHold(sizeChange: CGSize, keyPress: Bool) {
        guard hold == nil, sizeChange != .zero else { return }
        let next = CGSize(width: max(0, bounds.width + sizeChange.width), height: max(0, bounds.height + sizeChange.height))
        for case let follower as any PaneMotionHoldFollowing in subviews where follows(follower) {
            follower.drawAheadOfFollow(nextHostSize: next, keyPress: keyPress)
        }
    }

    /// A snapped change that drew its followers' sizes ahead (``drawAheadOfHold(sizeChange:keyPress:)``) showed: each
    /// follower lets a size its placement did not take go (``PaneMotionHoldFollowing/aheadOfFollowShown()``).
    public func aheadOfHoldShown() {
        for case let follower as any PaneMotionHoldFollowing in subviews { follower.aheadOfFollowShown() }
    }

    /// Whether a key press's snap must keep waiting for a follower's size drawn ahead
    /// (``PaneMotionHoldFollowing/aheadOfFollowAwaitsContent(refreshesWaited:)``, RESIZE P0 20).
    public func aheadOfHoldAwaitsContent(refreshesWaited: Int) -> Bool {
        subviews.contains { ($0 as? any PaneMotionHoldFollowing)?.aheadOfFollowAwaitsContent(refreshesWaited: refreshesWaited) == true }
    }

    /// A key press's held snap shows in this turn: no follower waits longer
    /// (``PaneMotionHoldFollowing/aheadOfFollowWillShow()``, RESIZE P0 21).
    public func aheadOfHoldWillShow() {
        for case let follower as any PaneMotionHoldFollowing in subviews { follower.aheadOfFollowWillShow() }
    }

    /// A container in it was shown again during a following hold (a parked tab): it joins in this frame's layout pass.
    public func followerDidShow() {
        if hold != nil { needsLayout = true }
    }

    public override func layout() { // perf-hot: 4ms motion-frame
        super.layout()
        showHeld(handing: false)
    }

    /// A shown container that follows now (a hidden one, a parked tab, stays held and lays out at the release).
    private func follows(_ follower: any PaneMotionHoldFollowing) -> Bool { !follower.isHidden && follower.followsPaneMotion }

    /// A container that joins during a following hold (a tab switch) follows from now on. It came in at the held rect
    /// (``contentBounds``), so what it measured on its way in (a terminal's rest size) is from the held size, as for the
    /// containers that were there when the hold began.
    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let heldSize, let hold, let follower = subview as? any PaneMotionHoldFollowing, follows(follower),
              handed.insert(ObjectIdentifier(follower)).inserted else { return }
        follower.followPaneMotion(hold, heldSize: heldSize)
        if follower.frame != bounds {
            follower.frame = bounds
            follower.needsLayout = true
        }
    }

    /// A container that leaves during a following hold (a tab moved to another pane) stops following.
    public override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard handed.remove(ObjectIdentifier(subview)) != nil, let follower = subview as? any PaneMotionHoldFollowing else { return }
        follower.followPaneMotion(nil, heldSize: nil)
    }

    /// The hold ended: each subview takes the area's size as autoresizing from `held` places it; one that fills the area
    /// (one that joined during the hold too, at the size it joined at) fills it now. A container that followed hears the
    /// end first, so it lays its producer out at this size.
    private func release(from held: CGSize) {
        let followed = handed
        (heldSize, handed) = (nil, [])
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
        for view in subviews {
            if followed.contains(ObjectIdentifier(view)) { (view as? any PaneMotionHoldFollowing)?.followPaneMotion(nil, heldSize: nil) }
            if view.autoresizingMask.isSuperset(of: [.width, .height]) {
                if view.frame != bounds { view.frame = bounds }
            } else {
                view.resize(withOldSuperviewSize: held)
            }
        }
        endedHold = true
        superview?.needsLayout = true
    }

    /// The pane's own ground as it shows now (FRAME OWNER S3c: read when the pane closes, and in each frame of a spring that
    /// holds its content, SPLIT OPEN CHAT): the background of the
    /// topmost shown view that fills the area (a terminal's host paints the terminal's ground), else the area's own; nil
    /// when the pane shows the window's sheet (a see-through window).
    /// A view that reports its own ground (``PaneGroundReporting``: a browser's chrome, whose page paints over the chrome's
    /// window-colored layer) gives that one first.
    public var groundColor: CGColor? {
        for view in subviews.reversed() where !view.isHidden && view.frame.contains(bounds.insetBy(dx: 0.5, dy: 0.5)) {
            if let ground = (view as? any PaneGroundReporting)?.paneGround, ground.alpha > 0 { return ground }
            if let color = view.layer?.backgroundColor, color.alpha > 0 { return color }
        }
        return layer?.backgroundColor.flatMap { $0.alpha > 0 ? $0 : nil }
    }
}

/// A view in a pane's content area whose ground is not its layer's background (CLOSE MOTION 2 case 3, cmux-ad m48): a
/// browser's chrome paints the window's color under the page, and a closing page pane must show the page's own
/// background, not the window's. Read when its pane closes and in each frame of a spring that holds its pane's content
/// (SPLIT OPEN CHAT), on the main thread: O(1), no page script.
@MainActor
public protocol PaneGroundReporting: NSView {
    /// The ground its pane shows when it closes; nil: its layer's background, as any other view.
    var paneGround: CGColor? { get }
}

public extension NSView {
    /// The pane ground this pane content shows (FRAME OWNER S3c: read when its pane closes, and in each frame of a spring
    /// that holds it): its content area's (``PaneContentAreaView/groundColor``), else its own background; nil for none
    /// (a see-through window's sheet).
    var paneGroundColor: CGColor? {
        if let area = self as? PaneContentAreaView ?? subviews.lazy.compactMap({ $0 as? PaneContentAreaView }).first { return area.groundColor }
        return layer?.backgroundColor
    }

    /// How far from this pane content's top and leading edges its ground (``paneGroundColor``) starts: where its content
    /// area is laid out now (below a tab strip at its top edge, after a vertical tab list), and below the rows of a tab
    /// row that a view in the area shares with the pane's tabs (``tabRowCoverHeight``: the area then starts at the top,
    /// under the row, and no ground goes behind or beside the tabs). Zeros for a chat with no strip: it paints from its
    /// top edge, whatever header its pane reports for its ring. Nil: it has no content area of its own (it is one, or it
    /// shows none). A row's tools that enter or leave the row move the area and the cover in one layout, by the same
    /// height, so the top is the same before and after that layout.
    /// Read in each frame of a spring that holds the content: O(the area's views), no layout.
    var paneGroundInsets: (top: CGFloat, leading: CGFloat)? {
        guard !(self is PaneContentAreaView), let area = subviews.lazy.compactMap({ $0 as? PaneContentAreaView }).first else { return nil }
        let top = isFlipped ? area.frame.minY - bounds.minY : bounds.maxY - area.frame.maxY
        let row = area.subviews.reduce(0) { $1.isHidden ? $0 : max($0, $1.tabRowCoverHeight) }
        return (top: max(0, top) + row, leading: max(0, area.frame.minX - bounds.minX))
    }
}
