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
            if hold == nil, let held = heldSize { release(from: held) } else { showHeld() }
        }
    }

    /// The area's size when the hold began: the size its subviews keep; nil at rest.
    private var heldSize: CGSize?

    /// Whether the subviews are held now.
    public var isHolding: Bool { heldSize != nil }

    /// The rect a view that fills the area takes: its bounds at rest; while it holds, the held content's rect, so a view
    /// that joins mid-hold (a tab switch) is held with the rest and its pane's rest-size change applies to it too.
    public var contentBounds: CGRect { heldSize.map { CGRect(origin: .zero, size: $0) } ?? bounds }

    /// A hold ended since the last call: the owner runs, once, the work it left alone during the hold.
    public func takeEndedHold() -> Bool {
        defer { endedHold = false }
        return endedHold
    }

    private var endedHold = false

    public override func setFrameSize(_ newSize: NSSize) { // perf-hot: 4ms motion-frame
        super.setFrameSize(newSize)
        showHeld()
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

    /// The held subviews on the hold's edges of the area's size now: one bounds write, no subview frame changes.
    private func showHeld() {
        guard let heldSize, let hold else { return }
        let origin = hold.boundsOrigin(holding: heldSize, in: bounds.size)
        if bounds.origin != origin { setBoundsOrigin(origin) }
    }

    /// The hold ended: each subview takes the area's size as autoresizing from `held` places it; one that fills the area
    /// (one that joined during the hold too, at the size it joined at) fills it now.
    private func release(from held: CGSize) {
        heldSize = nil
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
        for view in subviews {
            if view.autoresizingMask.isSuperset(of: [.width, .height]) {
                if view.frame != bounds { view.frame = bounds }
            } else {
                view.resize(withOldSuperviewSize: held)
            }
        }
        endedHold = true
        superview?.needsLayout = true
    }
}
