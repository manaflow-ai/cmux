import AppKit
import os

// cmux: real Messages blurs and darkens the header's avatar and name pill with the transcript under
// an open thread or reply view (thread-open-esc reference: the avatar 237 -> 103). The vendored
// window view keeps its thread layer (ThreadBackdrop, a live blur and tint, and the thread's rows)
// in its own layer tree, under the in-pane header (`PaneHeaderView`, AppKit views above that tree),
// so the header stayed sharp. As the morph and compose layers are hosted on their own (HostView
// install), the thread layer's CALayer moves to `threadHost`, a layer host above the header and
// below the selection, morph, field and compose hosts: the backdrop blurs and darkens the live
// header (its glass, title and avatar as drawn) on its own open and close curves, and the field
// stays above it. The thread layer view stays the window view's subview (frames, hit tests and
// scale walks are unchanged); only where its layer draws moves.
//
// The thread layer is the vendored `UIView` shim (appkit-port LayerViews.swift: an NSObject that
// owns a plain CALayer), not an NSView, so AppKit never re-attaches its layer; only the shim's own
// addSubview / insertSubview would (WindowView calls them for it in init only). `HostView.layout`
// checks the parent every pass and lifts it again if anything put it back.

extension HostView {
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// The window view's thread layer view, by its stored property's name (`threadLayer`, private to
    /// WindowView.swift; read by reflection, no vendored edit). If upstream renames it: a fault is
    /// logged and the view is found by its place and shape instead (`threadLayerByPlace`).
    static func threadLayerView(of demo: MessagesWindowView) -> UIView? {
        if let v = reflectedThreadLayer(of: demo) { return v }
        log.fault("Home: MessagesWindowView has no threadLayer property; finding the thread layer by its place")
        return threadLayerByPlace(of: demo)
    }

    /// The `threadLayer` stored property itself (nil when upstream renamed or removed it; a test fails then:
    /// PaneClickTests.theReflectedThreadLayerIsTheWindowViewsThreadLayer).
    static func reflectedThreadLayer(of demo: MessagesWindowView) -> UIView? {
        Mirror(reflecting: demo).children.first(where: { $0.label == "threadLayer" })?.value as? UIView
    }

    /// The fallback: WindowView's init adds clip, threadLayer, header, compose, ...; the thread layer
    /// is the subview after `clip` whose one child (`threadDim`) holds ThreadBackdrop's root (its
    /// blur and tint layers) and no subviews. Nil when nothing there has that shape.
    static func threadLayerByPlace(of demo: MessagesWindowView) -> UIView? {
        guard let i = demo.subviews.firstIndex(where: { $0 === demo.clip }), demo.subviews.indices.contains(i + 1) else { return nil }
        let v = demo.subviews[i + 1]
        guard v !== demo.header, v !== demo.compose, v !== demo.morphView, v.subviews.count == 1,
              let dim = v.subviews.first, dim.subviews.isEmpty,
              let root = dim.layer.sublayers?.first, !(root.sublayers ?? []).isEmpty else { return nil }
        return v
    }

    /// Moves the window view's thread layer into `threadHost` (install, and every layout pass when
    /// something moved it back). Logs a fault when the layer is not found and leaves the tree as it
    /// is (the header then stays sharp under an open thread, the 84ae154 baseline's gap); no crash.
    func liftThreadLayer(_ demo: MessagesWindowView) {
        if liftedThread == nil || liftedThread?.superview !== demo {
            // One search (and one fault) per window view, not one per layout pass.
            guard threadLayerSearch != ObjectIdentifier(demo) else { return }
            threadLayerSearch = ObjectIdentifier(demo)
            liftedThread = Self.threadLayerView(of: demo)
            if liftedThread == nil {
                Self.log.fault("Home: no thread layer found; the header is not blurred under a thread")
                return
            }
        }
        guard let thread = liftedThread, thread.layer.superlayer !== threadHost.root else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        threadHost.root.addSublayer(thread.layer)
        CATransaction.commit()
    }

    /// cmux: under an open thread or reply view the header (its avatar and pill) blurs and darkens with
    /// the transcript, and no thread row draws over it. One backdrop does it: the vendored thread layer
    /// (ThreadBackdrop, then the thread's rows) sits over the live header in `threadHost`, unmasked, so
    /// the header band and the transcript are one blur and one tint, on the same frames, with no seam
    /// (round 7: a second backdrop over the band joined the vendored one with a 5.4-level step at 80 pt
    /// and ran 0-3 frames behind it).
    ///
    /// The thread's rows are clipped out of the header band instead, each by a mask of its own (the
    /// row layers stay where the vendored view put them): the mask's top edge sits at the band's bottom
    /// (`Fixture.headerHeight`) in pane coordinates. A row flying in or out (ThreadBackdrop.fly, a
    /// keyframe animation of its `position.y`) carries its mask with it, so the mask gets the inverse
    /// keyframes on the same duration and begin time: its edge stays at the band's bottom on every
    /// frame. A row passes under the header, as under Messages' titlebar. Called after every engine
    /// change (the vendored view adds rows and their flights during a dispatch) and on layout.
    func clipThreadToHeader() {
        guard let thread = liftedThread, thread.layer.superlayer === threadHost.root,
              let dim = thread.subviews.first?.layer else { return }
        let band = min(Fixture.headerHeight, bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for row in thread.layer.sublayers ?? [] where row !== dim {
            Self.clipRow(row, belowY: band)
        }
    }

    /// The row's mask: everything at or below `y` (the thread layer's coordinates), following the row's flight.
    static func clipRow(_ row: CALayer, belowY y: CGFloat) {
        if let other = row.mask, other.name != Self.bandMaskName { return }  // a mask of the vendored view's own: left alone
        let mask = row.mask ?? CALayer()
        mask.name = Self.bandMaskName
        mask.actions = ["bounds": NSNull(), "position": NSNull()]
        mask.backgroundColor = NSColor.black.cgColor
        // The model frame: the row at its final place; the mask's top at `y` in the thread layer.
        let top = y - row.frame.minY
        let frame = CGRect(x: -4096, y: top, width: row.bounds.width + 8192, height: max(0, row.bounds.height - top) + 4096)
        if mask.frame != frame { mask.frame = frame }
        if row.mask !== mask { row.mask = mask }
        // The flight: the inverse keyframes, once per flight (a flight is known by its values).
        let fly = row.animation(forKey: "thread.fly") as? CAKeyframeAnimation
        let values = (fly?.values as? [NSNumber])?.map(\.doubleValue)
        // The followed flight's values, kept on the mask (CALayer's key-value storage).
        guard values != mask.value(forKey: Self.followedKey) as? [Double] else { return }
        mask.setValue(values, forKey: Self.followedKey)
        mask.removeAnimation(forKey: "cmux.band")
        guard let fly, let values else { return }
        let rowY = row.position.y, maskY = mask.position.y
        let k = CAKeyframeAnimation(keyPath: "position.y")
        k.values = values.map { NSNumber(value: Double(maskY) - ($0 - Double(rowY))) }
        k.keyTimes = fly.keyTimes
        k.duration = fly.duration
        k.calculationMode = fly.calculationMode
        k.beginTime = fly.beginTime
        k.fillMode = fly.fillMode
        k.timingFunctions = fly.timingFunctions
        mask.add(k, forKey: "cmux.band")
    }

    static let bandMaskName = "cmux.threadBand", followedKey = "cmuxFollowedFlight"

    /// The thread view's open state, followed after every engine change.
    func followThread(open: Bool) {
        clipThreadToHeader()
        veilOpen = open
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
