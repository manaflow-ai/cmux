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
/// keeps its size.
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

    /// The pane's own ground as it shows now (FRAME OWNER S3c, read once when the pane closes): the background of the
    /// topmost shown view that fills the area (a terminal's host paints the terminal's ground), else the area's own; nil
    /// when the pane shows the window's sheet (a see-through window).
    public var groundColor: CGColor? {
        for view in subviews.reversed() where !view.isHidden && view.frame.contains(bounds.insetBy(dx: 0.5, dy: 0.5)) {
            if let color = view.layer?.backgroundColor, color.alpha > 0 { return color }
        }
        return layer?.backgroundColor.flatMap { $0.alpha > 0 ? $0 : nil }
    }
}

public extension NSView {
    /// The pane ground this pane content shows (FRAME OWNER S3c, read once when its pane closes): its content area's
    /// (``PaneContentAreaView/groundColor``), else its own background; nil for none (a see-through window's sheet).
    var paneGroundColor: CGColor? {
        if let area = self as? PaneContentAreaView ?? subviews.lazy.compactMap({ $0 as? PaneContentAreaView }).first { return area.groundColor }
        return layer?.backgroundColor
    }
}
