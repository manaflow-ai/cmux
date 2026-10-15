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

    /// cmux: nothing of the thread view draws over the header's controls (round 4 and 5 captures:
    /// in a light close, thread rows flying back under the header drew over the avatar and pill).
    /// No vendored layer is moved for it:
    /// - `threadHost` (the vendored thread layer: its backdrop and rows) is masked out at the avatar's
    ///   disc and the pill's capsule, so a row passes under the controls, as transcript rows do;
    /// - `headerVeil`, over the header and masked to those same shapes, holds ThreadBackdrop's tint (its
    ///   colour, opacity and curves: out = 5.5 + 0.384 x in), faded in the same turn as the window
    ///   view's backdrop (`followThread`), so the controls darken with the transcript on the same
    ///   frames. No blur there: a second CABackdropLayer over the controls captured nothing in light
    ///   appearance (round 6: dark shapes with a light outline, no letter), so the controls show
    ///   dimmed and sharp, their letter and title still readable (Messages: faint).
    /// Updated on layout (the controls' places) and after every engine change (open and close).
    func clipThreadToHeader() {
        let holes = paneHeader.controlRects(width: bounds.width)
        guard holes != threadHoles || veilTint.superlayer !== headerVeil.root else { return }
        threadHoles = holes
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if veilTint.superlayer !== headerVeil.root {
            veilTint.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
            veilTint.backgroundColor = NSColor(white: ThreadBackdrop.base / 255 / (1 - ThreadBackdrop.gain), alpha: 1).cgColor
            veilTint.opacity = 0
            headerVeil.root.addSublayer(veilTint)
        }
        veilTint.frame = bounds
        func shapes(_ path: CGMutablePath) {
            for r in holes { path.addRoundedRect(in: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2) }
        }
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -4096, dy: -4096))
        shapes(outside)
        let inside = CGMutablePath()
        shapes(inside)
        threadHost.root.mask = Self.shapeMask(outside, evenOdd: true, frame: bounds, reuse: threadHost.root.mask)
        headerVeil.root.mask = Self.shapeMask(inside, evenOdd: false, frame: bounds, reuse: headerVeil.root.mask)
    }

    private static func shapeMask(_ path: CGPath, evenOdd: Bool, frame: CGRect, reuse: CALayer?) -> CAShapeLayer {
        let m = (reuse as? CAShapeLayer) ?? CAShapeLayer()
        m.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        m.fillRule = evenOdd ? .evenOdd : .nonZero
        m.frame = frame
        m.path = path
        return m
    }

    /// The veil's tint opens and closes with the window view's thread view (after every engine change,
    /// in the same turn as the vendored open or close): ThreadBackdrop.animate's tint, the same
    /// opacity, duration and curve, begun at the same commit.
    func followThread(open: Bool) {
        clipThreadToHeader()
        guard open != veilOpen else { return }
        veilOpen = open
        let d = open ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration
        let to: Float = open ? Float(1 - ThreadBackdrop.gain) : 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = veilTint.presentation()?.opacity ?? veilTint.opacity
        a.toValue = to
        a.duration = d
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        veilTint.opacity = to
        veilTint.add(a, forKey: "thread")
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
