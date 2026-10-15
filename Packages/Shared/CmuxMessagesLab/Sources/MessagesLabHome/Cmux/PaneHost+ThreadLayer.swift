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

    // cmux: under an open thread or reply view the transcript and the whole header, avatar and name
    // pill, blur and darken, and the thread's rows pass under the header, as under Messages' titlebar.
    // The vendored thread layer (ThreadBackdrop, then the rows) sits in `threadHost`, unmasked, under the
    // header; the header takes the backdrop's blur and tint itself (PaneHeaderView.setThreadBlur), on the
    // vendored animations' own timing, read here. Rows render once, uncut (round 9); none draws over the
    // avatar on a close (round 10: a row flying back to its place under the header covered the avatar
    // for 0.35 s while the thread layer was over the header).

    /// The vendored backdrop's layers (ThreadBackdrop: its root holds the blur, when the system has one,
    /// then the tint), read for their animations' timing; nil if the layout changes upstream.
    var vendoredBackdropRoot: CALayer? { liftedThread?.subviews.first?.layer.sublayers?.first }

    /// The thread view's open state, followed after the engine changes that matter: the header blurs and
    /// dims with the backdrop, on its animations' begin time, duration and curve.
    func followThread(open: Bool) {
        veilOpen = open
        let parts = vendoredBackdropRoot?.sublayers ?? []
        let tint = parts.last?.animation(forKey: "thread") as? CABasicAnimation
        let blur = parts.count > 1 ? parts.first?.animation(forKey: "thread") as? CABasicAnimation : nil
        paneHeader.setThreadBlur(open: open, blur: blur ?? tint, tint: tint)
    }

    /// The thread layer holds rows (a thread view open or closing).
    var threadRowsShown: Bool {
        guard let thread = liftedThread else { return false }
        return (thread.layer.sublayers?.count ?? 0) > 1
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
