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
        if let v = Mirror(reflecting: demo).children.first(where: { $0.label == "threadLayer" })?.value as? UIView { return v }
        log.fault("Home: MessagesWindowView has no threadLayer property; finding the thread layer by its place")
        return threadLayerByPlace(of: demo)
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

    /// cmux: the thread's rows over the header (round 4 capture: in a light close, thread rows flying
    /// back to their places under the header drew over the avatar for 14 frames; in an open a row
    /// covered the pill). The thread's row layers (the thread layer's sublayers other than
    /// ThreadBackdrop's `threadDim`) move into `threadRows`, one container masked out at the avatar's
    /// disc and the pill's capsule: a row passes under the header's controls, as transcript rows do,
    /// while the backdrop under them still blurs the controls. Called after every engine change (the
    /// vendored thread view adds its rows during a dispatch) and on layout (the controls' places).
    func clipThreadRows() {
        guard let thread = liftedThread, thread.layer.superlayer === threadHost.root,
              let dim = thread.subviews.first?.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if threadRows.superlayer !== thread.layer {
            threadRows.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
            thread.layer.insertSublayer(threadRows, above: dim)
        }
        for l in thread.layer.sublayers ?? [] where l !== dim && l !== threadRows { threadRows.addSublayer(l) }
        if threadRows.frame != thread.layer.bounds { threadRows.frame = thread.layer.bounds }
        let holes = paneHeader.controlRects(width: bounds.width)
        guard holes != threadRowsHoles else { return }
        threadRowsHoles = holes
        let mask = (threadRows.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        mask.fillRule = .evenOdd
        mask.frame = threadRows.bounds
        let path = CGMutablePath()
        path.addRect(threadRows.bounds.insetBy(dx: -4096, dy: -4096))
        for r in holes { path.addRoundedRect(in: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2) }
        mask.path = path
        threadRows.mask = mask
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
