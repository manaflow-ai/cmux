import AppKit
import CmuxNextDesign

/// Snapshot-first right split (goal instant-splits, prototype behind `DesignSettings.splitSnapshotOpen`, off by
/// default). The live path shows a split only once its new pane is mounted, laid out and drawn at its size (the held
/// snap, `ScreenContentView+SnapFrame`). With the flag on, a split that only cuts one pane in two side by side opens
/// first as a retained picture: in the key's turn, before any host is made or laid out, the new pane's end rect is
/// computed once from the new layout and kept fixed, a picture of the new pane (its ground and its leading divider)
/// joins the layer tree at that rect, starts a compositor slide in from the split pane's right edge, and that
/// transaction is flushed to the render server at once. Nothing in the slide waits on live content: no layout, no page
/// resize, no repaint. The live change mounts underneath and shows when its content drew; once it showed and the slide
/// landed, the picture goes. The panes' own commit motion does not run for this change: the slide is its motion.
@MainActor
final class SplitSnapshotOpen {
    /// The slide's length: short enough that the live view is under it by the end (the held snap waits at most 8 ticks).
    static let slide: CFTimeInterval = 0.12
    /// The picture goes by then whatever happens (a change that never shows).
    static let failsafe: TimeInterval = 1

    let view: NSView
    /// The new pane's end rect in the screen view's coordinates, fixed at the key press.
    let end: CGRect
    /// The live change showed under the picture (``ScreenContentView/beginShowingChange()``).
    var liveShown = false
    /// The compositor's slide landed (its transaction's completion).
    var landed = false

    init(view: NSView, end: CGRect) {
        self.view = view
        self.end = end
    }

    /// Both happened: the picture goes.
    var done: Bool { liveShown && landed }

    /// Adds `slide` to `layer` in a transaction of its own; when the compositor ran it, marks the slide landed and calls
    /// `landed` (the owner drops the picture if the live change showed by then).
    func run(_ slide: CAAnimation, on layer: CALayer?, landed: @escaping @MainActor (SplitSnapshotOpen) -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { // main-proof: a transaction begun on the main thread completes there
                guard let self else { return }
                self.landed = true
                landed(self)
            }
        }
        layer?.add(slide, forKey: "splitSnapshotOpen")
        CATransaction.commit()
    }
}

/// A picture that takes no clicks: the live panes under it keep their events.
private final class SnapshotOpenView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension ScreenContentView {
    /// The change to `layout` is a plain right split: the screen shows in a window, no canvas, no zoom and no floating
    /// pane, the change adds exactly one pane, and the new layout only cuts one pane in two side by side, the new one on
    /// the right, every other pane where it was. Returns the split pane's host and the new pane's end rect in this
    /// view's coordinates. Such a change is timed (`right_split_open`) and, with the flag on, opens from a picture.
    func rightSplit(to layout: ScreenLayout, zoomed: Bool, canvas: CanvasScreen?) -> (giver: PaneHostView, end: CGRect)? {
        guard window != nil, !isHiddenOrHasHiddenAncestor, bounds.width > 0,
              canvas == nil, canvasState.canvas == nil, !self.zoomed, !zoomed,
              floatState.shown.isEmpty, rowDragPreview == nil, layout.panes.count == self.layout.panes.count + 1 else { return nil }
        let old = Set(self.layout.panes), new = Set(layout.panes)
        guard new.isStrictSuperset(of: old), let added = new.subtracting(old).first else { return nil }
        // The end, once: the new layout's geometry at this viewport, as the reconcile after it computes it.
        let next = ScreenGeometry.compute(layout, viewport: bounds.size, style: context.style, scale: scale)
        guard let end = next.panes[added] else { return nil }
        var giver: PaneID?
        for (pane, rect) in baseGeometry.panes {
            guard let now = next.panes[pane] else { return nil }
            if now.equalTo(rect) { continue }
            // The one pane that changes keeps its left, top and height and gives its right part to the new pane.
            guard giver == nil, abs(now.minX - rect.minX) < 0.5, abs(now.minY - rect.minY) < 0.5, abs(now.height - rect.height) < 0.5,
                  end.minX >= now.maxX - 0.5, end.maxX <= rect.maxX + 0.5, abs(end.minY - rect.minY) < 0.5,
                  abs(end.height - rect.height) < 0.5 else { return nil }
            giver = pane
        }
        guard let giver, let host = context.hosts[giver], host.superview === self, let oldRect = baseGeometry.panes[giver] else { return nil }
        let shift = CGPoint(x: host.frame.minX - oldRect.minX, y: host.frame.minY - oldRect.minY)
        return (host, end.offsetBy(dx: shift.x, dy: shift.y))
    }

    /// Puts the picture of the new pane over the split pane's place and slides it in on the compositor, then flushes
    /// that transaction: the frame that shows the split begin is handed over now, in the key's turn, before the new
    /// pane's host is made. The timing (``TransitionFrameLog/Transition/rightSplitOpen``) ends at that commit.
    func openSplitFromSnapshot(giver: PaneHostView, end: CGRect) {
        dropSnapshotOpen()
        let clip = SnapshotOpenView(frame: giver.frame)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        let picture = SnapshotOpenView(frame: end.offsetBy(dx: -giver.frame.minX, dy: -giver.frame.minY))
        picture.wantsLayer = true
        picture.layer?.backgroundColor = Palette.paneFill.withAlphaComponent(1).cgColor
        picture.layer?.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        // The new pane's leading divider comes with it.
        let line = SnapshotOpenView(frame: CGRect(x: 0, y: 0, width: max(1, context.style.dividerThickness), height: end.height))
        line.wantsLayer = true
        line.layer?.backgroundColor = dividerViews.values.lazy.compactMap(\.lineColor).first ?? NSColor.separatorColor.cgColor
        picture.addSubview(line)
        clip.addSubview(picture)
        addSubview(clip, positioned: .above, relativeTo: nil)
        // From the split pane's right edge to the fixed end: additive on x, so the model value is the end throughout.
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = giver.frame.width - picture.frame.minX
        slide.toValue = 0
        slide.isAdditive = true
        slide.duration = SplitSnapshotOpen.slide
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slide.fillMode = .backwards
        let state = SplitSnapshotOpen(view: clip, end: end)
        snapshotOpen = state
        state.run(slide, on: picture.layer) { [weak self] state in
            guard let self, self.snapshotOpen === state, state.done else { return }
            self.dropSnapshotOpen()
        }
        perform(#selector(dropSnapshotOpenFailsafe), with: nil, afterDelay: SplitSnapshotOpen.failsafe)
        markSnapshotSplit(giver: giver)
        CATransaction.flush()
    }

    /// The live change showed in this pass (``beginShowingChange()``): the picture goes in this pass's commit if its
    /// slide landed, else when it lands (the live panes are drawn under it by then).
    func snapshotOpenLiveShown() {
        guard let state = snapshotOpen else { return }
        state.liveShown = true
        if state.done { dropSnapshotOpen() }
    }

    @objc func dropSnapshotOpenFailsafe() {
        dropSnapshotOpen()
    }

    func dropSnapshotOpen() {
        guard let state = snapshotOpen else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(dropSnapshotOpenFailsafe), object: nil)
        snapshotOpen = nil
        state.view.removeFromSuperview()
    }
}
