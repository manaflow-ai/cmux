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

    /// cmux: under an open thread or reply view the header's avatar and pill blur and darken with the
    /// transcript (Messages: the avatar 237 -> 103, its letter and the pill's title faint), and nothing
    /// of the thread view draws over them. No vendored layer is moved for it, and no mask cuts a
    /// backdrop at the controls' edges:
    /// - `threadHost` (the vendored thread layer: its backdrop and the thread's rows) draws only below
    ///   the header band (a rectangular mask from `Fixture.headerHeight` down), so a thread row passes
    ///   under the header, as under Messages' titlebar;
    /// - `headerVeil`, over the header band only, holds a ThreadBackdrop of its own (the vendored class:
    ///   the same live Gaussian blur, radius `ThreadBackdrop.radius`, and tint, 5.5 + 0.384 x in) over
    ///   the whole band, opened and closed in the same turn as the window view's (`followThread`), so
    ///   the band, the avatar and the pill included, blurs and darkens on the same frames and curve as
    ///   the transcript below it.
    /// Round 6 had a backdrop masked to the controls' shapes: its blur ended at the shapes' edges (a
    /// light rim, the shapes dark and flat). Over the whole band the blur runs past the controls into
    /// the band as the vendored one does past every edge. Updated on layout and after every engine change.
    func clipThreadToHeader() {
        let band = CGRect(x: 0, y: 0, width: bounds.width, height: min(Fixture.headerHeight, bounds.height))
        guard band != threadBand || veilBackdrop.root.superlayer !== headerVeil.root else { return }
        threadBand = band
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if veilBackdrop.root.superlayer !== headerVeil.root { headerVeil.root.addSublayer(veilBackdrop.root) }
        veilBackdrop.frame = band
        let below = (threadHost.root.mask) ?? CALayer()
        below.actions = ["bounds": NSNull(), "position": NSNull()]
        below.backgroundColor = NSColor.black.cgColor
        below.frame = CGRect(x: -4096, y: band.maxY, width: bounds.width + 8192, height: max(0, bounds.height - band.maxY) + 4096)
        threadHost.root.mask = below
    }

    /// The veil's backdrop opens and closes with the window view's thread view, after every engine
    /// change, in the same turn as the vendored open or close (ThreadBackdrop.animate: the same blur
    /// radius, tint, durations and curve, begun at the same commit).
    func followThread(open: Bool) {
        clipThreadToHeader()
        guard open != veilOpen else { return }
        veilOpen = open
        veilBackdrop.animate(open: open)
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
