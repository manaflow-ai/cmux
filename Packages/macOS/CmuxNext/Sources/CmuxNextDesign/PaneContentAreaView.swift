public import AppKit
import QuartzCore

/// A pane's content area, under its tab strip: the one rounded container its terminal, page or chat shows in. It clips
/// to its bounds.
///
/// Every view shown in it has the area's size in every frame, at rest and in every motion of its pane (Lawrence
/// 2026-11-11: "check all pane types, all must have smooth transition"). While ``hold`` is set (a keyboard resize), the
/// area's frame follows the pane in every frame and so does what it shows: a view resizes as its autoresizing says, as
/// in a divider drag, and lays out in that frame's layout pass. Nothing shown keeps the size it had when the hold began.
///
/// A container whose producer draws on another thread or in another process (``PaneMotionHoldFollowing``: a terminal's
/// host, a browser's chrome; FRAME OWNER S3) also hears the hold, once: the area gives it its bounds in every frame, and
/// its producer reads the hold's edges for a frame that is late (a terminal's surface, cmux-ad m6 and m18).
///
/// A view that fills the area and is hidden (a parked page) does no work in the hold: it takes the area's size once,
/// when the hold ends or when it shows.
///
/// One exception, which a kind states (``PaneKeyResizeHeld``; today the Home): its view keeps the size it had when the
/// hold began, on the hold's edges, and takes the area's size once, when the hold ends.
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

    /// The edges of the pane that stay in a keyboard resize, for the producers that hear the hold; nil at rest. Setting
    /// nil ends it at once (``release()``).
    public var hold: PaneMotionHold? {
        didSet {
            guard hold != oldValue else { return }
            if hold != nil, heldSize == nil { heldSize = bounds.size }
            if hold == nil, heldSize != nil { release() } else { follow(handing: true) }
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

    /// The area's size when the hold began: what a producer that hears the hold measures its pane's size change from;
    /// nil at rest.
    private var heldSize: CGSize?

    /// Whether a hold is on now (a keyboard resize moves the pane).
    public var isHolding: Bool { heldSize != nil }

    /// The rect `view` takes when it fills the area: the area's bounds. A container that hears the hold
    /// (``PaneMotionHoldFollowing``) and joins it now (a tab switch) comes in at the rect the area had when the hold
    /// began, so what it measures on its way in (a terminal's rest size) is from that size; the area gives it its bounds
    /// in the same turn (``didAddSubview(_:)``) or when it shows (``followerDidShow()``).
    public func contentBounds(for view: NSView) -> CGRect {
        guard let heldSize, view is any PaneMotionHoldFollowing, !handed.contains(ObjectIdentifier(view)) else { return bounds }
        return CGRect(origin: .zero, size: heldSize)
    }

    /// Whether the area gives `view` its frame in every frame of this hold (a container handed the hold, or one shown
    /// now that the area hands in this layout pass, ``followerDidShow()``): its owner leaves that frame alone until the
    /// hold ends, so the container hears the hold before its first layout at the pane's size.
    public func placesInHold(_ view: NSView) -> Bool {
        if handed.contains(ObjectIdentifier(view)) || keepsSizeInHold(view) { return true }
        guard heldSize != nil, let follower = view as? any PaneMotionHoldFollowing else { return false }
        return follows(follower)
    }

    /// The containers handed this hold (``PaneMotionHoldFollowing``), which the area places until it ends: one shown or
    /// added during the hold hears it in its first frame; one whose producer stops holding (a page whose DevTools docked)
    /// keeps following and lays its producer out live.
    private var handed: Set<ObjectIdentifier> = []

    /// A hold ended since the last call: the owner runs, once, the work it left alone during the hold.
    public func takeEndedHold() -> Bool {
        defer { endedHold = false }
        return endedHold
    }

    private var endedHold = false

    public override func setFrameSize(_ newSize: NSSize) { // perf-hot: 4ms motion-frame
        super.setFrameSize(newSize)
        follow(handing: false)
    }

    /// In a hold every shown view resizes as at rest and lays out in this frame's pass. Not the containers handed the
    /// hold (``follow(handing:)`` gives them the area's bounds), and not a hidden view that fills the area (a parked page:
    /// one size when the hold ends or when it shows, ``release()``).
    public override func resizeSubviews(withOldSize oldSize: NSSize) { // perf-hot: 4ms motion-frame
        guard heldSize != nil else { return super.resizeSubviews(withOldSize: oldSize) }
        for view in subviews where !handed.contains(ObjectIdentifier(view)) && !(view.isHidden && fillsArea(view)) && !keepsSizeInHold(view) {
            let size = view.frame.size
            view.resize(withOldSuperviewSize: oldSize)
            if view.frame.size != size { view.needsLayout = true }
        }
    }

    /// A view that takes the area's whole size as the area changes (the selected tab's content, a parked page).
    private func fillsArea(_ view: NSView) -> Bool { view.autoresizingMask.isSuperset(of: [.width, .height]) }

    /// Whether `view` keeps its size through this hold: the exception a kind states (``PaneKeyResizeHeld``; the Home). The
    /// area puts it on the hold's edges in each frame (``follow(handing:)``, an origin write, no layout) and gives it its
    /// bounds once, when the hold ends (``release()``); its owner leaves its frame alone until then.
    public func keepsSizeInHold(_ view: NSView) -> Bool { fillsArea(view) && keepsOutOfTabRowInHold(view) }

    /// Whether `view` states the exception (``PaneKeyResizeHeld``; the Home) while this hold is on: its pane gives it no
    /// tab row until the hold ends. Also before the view fills the area (a parked Home shown by a tab change inside the
    /// hold comes in at the frame it was parked at, ``keepsSizeInHold(_:)`` false in its first layout): it takes the
    /// area's size under the strip once, then keeps it. With the row it took the pane's whole size in that layout and
    /// kept it while the area went back under the strip, its tools in a band under the strip until the landing.
    public func keepsOutOfTabRowInHold(_ view: NSView) -> Bool {
        heldSize != nil && (view as? any PaneKeyResizeHeld)?.holdsInKeyResize == true
    }

    /// The area that a key hold of the pane that shows `content` uses: this one. Nil (the pane's host holds the whole
    /// pane, its tab strip too, as every pane did before 2026-11-11) for content that states the exception
    /// (``PaneKeyResizeHeld``; the Home) while it draws its tools in the pane's tab row: the row cannot follow the pane
    /// beside tools that keep their place.
    public func holdArea(for content: NSView?, drawsInTabRow: @autoclosure () -> Bool) -> PaneContentAreaView? {
        (content as? any PaneKeyResizeHeld)?.holdsInKeyResize == true && drawsInTabRow() ? nil : self
    }

    /// Rounds the area's corners (0: square), with no implicit animation.
    public func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }

    /// Each container that hears the hold takes the area's bounds (one frame write). `handing`: the hold changed, they
    /// hear it.
    private func follow(handing: Bool) { // perf-hot: 4ms motion-frame
        guard let heldSize, let hold else { return }
        for view in subviews where !view.isHidden && keepsSizeInHold(view) {
            let origin = hold.producerFrame(view.frame.size, in: bounds).origin
            if view.frame.origin != origin { view.setFrameOrigin(origin) }
        }
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

    /// A container in it was shown again during a hold (a parked tab): it joins in this frame's layout pass.
    public func followerDidShow() {
        if hold != nil { needsLayout = true }
    }

    public override func layout() { // perf-hot: 4ms motion-frame
        super.layout()
        follow(handing: false)
    }

    /// A shown container that hears the hold now (a hidden one, a parked tab, hears it when it shows).
    private func follows(_ follower: any PaneMotionHoldFollowing) -> Bool { !follower.isHidden && follower.followsPaneMotion }

    /// A container that joins during a hold (a tab switch) hears it from now on. It came in at the rect the area had when
    /// the hold began (``contentBounds(for:)``), so what it measured on its way in (a terminal's rest size) is from that
    /// size, as for the containers that were there when the hold began.
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

    /// A container that leaves during a hold (a tab moved to another pane) hears no more of it.
    public override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard handed.remove(ObjectIdentifier(subview)) != nil, let follower = subview as? any PaneMotionHoldFollowing else { return }
        follower.followPaneMotion(nil, heldSize: nil)
    }

    /// The hold ended: a container that heard it hears the end, so it lays its producer out at this size; a view that
    /// fills the area and did not resize in the hold (a hidden one, a parked page) fills it now. Every other view is at
    /// its size already: it resized in each frame.
    private func release() {
        let followed = handed
        (heldSize, handed) = (nil, [])
        for view in subviews {
            if followed.contains(ObjectIdentifier(view)) { (view as? any PaneMotionHoldFollowing)?.followPaneMotion(nil, heldSize: nil) }
            if fillsArea(view), view.frame != bounds { view.frame = bounds }
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
