public import AppKit
public import CmuxNextDesign

/// The band a pane draws over a chat's own tools while a resize drag moves its tab row (``PaneTabRowStandIn``): opaque
/// under the window's rim, with the chat's tools drawn by a ``PaneToolbarView`` through its native-items path, trailing
/// at the band's trailing edge. Shown at full strength whatever Minimal Mode does with the pane's own controls: the
/// page's tools it stands in for never hide at rest. Takes no clicks (only a drag shows it).
public final class PaneTabRowStandInView: NSView {
    /// The tools, laid out as the pane's toolbar lays out native row tools; wider than the band by the toolbar's
    /// trailing gap, which the band clips, so the last tool ends at the band's trailing edge.
    public let toolbar = PaneToolbarView(frame: .zero)

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(toolbar)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `standIn` at `frame` (its band in this view's superview's coordinates).
    public func show(_ standIn: PaneTabRowStandIn, at frame: CGRect) {
        if self.frame != frame { self.frame = frame }
        toolbar.show(nativeItems: standIn.tools)
        toolbar.reveal.isEnabled = false
        paintTabRowHole(standIn.fill, rim: standIn.rim)
        let toolbarFrame = CGRect(x: 0, y: 0, width: bounds.width + PaneToolbarView.trailingGap, height: bounds.height)
        if toolbar.frame != toolbarFrame { toolbar.frame = toolbarFrame }
        toolbar.layoutSubtreeIfNeeded()
    }
}

/// The pane's toolbar places its pane's stand-in band (``PaneTabRowStandInHosting``): in the toolbar's superview (the
/// pane), below its strip (a tab the band reaches stays drawn) and so below this toolbar, over the pane's content.
extension PaneToolbarView: PaneTabRowStandInHosting {
    public func placeTabRowStandIn(_ standIn: PaneTabRowStandIn?, from view: NSView?) {
        guard let pane = superview else { return }
        let existing = pane.subviews.lazy.compactMap { $0 as? PaneTabRowStandInView }.first
        guard let standIn, let view, view.isDescendant(of: pane) else {
            if let existing, !existing.isHidden { existing.isHidden = true }
            return
        }
        let band = existing ?? {
            let band = PaneTabRowStandInView(frame: .zero)
            let below = strip.flatMap { $0.superview === pane ? $0 : nil } ?? self
            pane.addSubview(band, positioned: .below, relativeTo: below)
            return band
        }()
        band.show(standIn, at: pane.convert(standIn.frame, from: view))
        if band.isHidden { band.isHidden = false }
    }
}
