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

    /// cmux: under an open thread or reply view, Messages blurs and darkens the transcript and the
    /// name pill, dims the avatar without blurring it (round 8 capture, same scale: its edges stay at
    /// 1.03 of rest), and the thread's rows pass under the header's controls, sharp, with no cut.
    /// - The vendored thread layer (ThreadBackdrop, then the thread's rows) sits over the live header in
    ///   `threadHost`, unmasked: the header band, the pill included, and the transcript are one blur and
    ///   one tint, on the same frames, with no seam.
    /// - The avatar draws in its own overlay over that (`PaneHeaderView.avatarOverlay`), dimmed by
    ///   ThreadBackdrop's tint on the same curve (`followThread`), never blurred. Rows pass under it.
    /// - Each thread row has a mask with a hole at the pill's capsule (thread-layer coordinates), so a
    ///   row passes under the pill too and is cut nowhere else. A row's flight (any animation of its
    ///   `position`, `position.x` or `position.y`: a copy of it with inverted values, the same timing)
    ///   moves its mask the other way, so the hole stays on the pill on every frame, whatever curve the
    ///   vendored view uses.
    /// Only while a thread view is open or its rows are still there (closing).
    func clipThreadToHeader() {
        guard let thread = liftedThread, thread.layer.superlayer === threadHost.root,
              let dim = thread.subviews.first?.layer else { return }
        let rows = (thread.layer.sublayers ?? []).filter { $0 !== dim }
        guard !rows.isEmpty else { return }
        let hole = paneHeader.pill.isHidden ? nil : threadHost.root.convert(paneHeader.pillBacking.frame, from: paneHeader.layer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for row in rows { Self.clipRow(row, hole: hole, in: thread.layer) }
    }

    static let bandMaskName = "cmux.threadPillHole", followedKey = "cmuxFollowedFlight"
    static let positionKeys: Set<String> = ["position", "position.x", "position.y"]

    /// The row's mask: all of it but `hole` (`space`'s coordinates), following the row's flights.
    static func clipRow(_ row: CALayer, hole: CGRect?, in space: CALayer) {
        if let other = row.mask, other.name != bandMaskName { return }  // a mask of the vendored view's own: left alone
        guard let hole else { row.mask = nil; return }
        let mask = (row.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.name = bandMaskName
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull()]
        mask.fillRule = .evenOdd
        if mask.frame != row.bounds { mask.frame = row.bounds }
        // The hole where the row's model (final) place puts the pill.
        let local = row.convert(hole, from: space)
        let path = CGMutablePath()
        path.addRect(row.bounds.insetBy(dx: -4096, dy: -4096))
        path.addRoundedRect(in: local, cornerWidth: local.height / 2, cornerHeight: local.height / 2)
        if mask.path != path { mask.path = path }
        if row.mask !== mask { row.mask = mask }
        // The flights: every position animation on the row, inverted on the mask, once per flight.
        let flights = (row.animationKeys() ?? []).compactMap { key -> (String, CAPropertyAnimation)? in
            guard let a = row.animation(forKey: key) as? CAPropertyAnimation, let path = a.keyPath, positionKeys.contains(path) else { return nil }
            return (key, a)
        }
        let signature = flights.map { "\($0.0)|\($0.1.beginTime)|\($0.1.duration)|\(String(describing: ($0.1 as? CAKeyframeAnimation)?.values ?? [($0.1 as? CABasicAnimation)?.fromValue as Any, ($0.1 as? CABasicAnimation)?.toValue as Any]))" }
        guard signature != mask.value(forKey: followedKey) as? [String] else { return }
        mask.setValue(signature, forKey: followedKey)
        for key in mask.animationKeys() ?? [] where key.hasPrefix("cmux.") { mask.removeAnimation(forKey: key) }
        for (key, a) in flights {
            if let inverse = invert(a, rowPosition: row.position, maskPosition: mask.position) { mask.add(inverse, forKey: "cmux." + key) }
        }
    }

    /// A copy of a position animation with values that move the mask by the opposite amount (an
    /// additive animation's deltas negated), its timing unchanged.
    static func invert(_ a: CAPropertyAnimation, rowPosition r: CGPoint, maskPosition m: CGPoint) -> CAPropertyAnimation? {
        guard let path = a.keyPath, let copy = a.copy() as? CAPropertyAnimation else { return nil }
        func flip(_ v: Any?) -> Any? {
            switch (path, v) {
            case ("position", let p as NSValue):
                let q = p.pointValue
                return NSValue(point: copy.isAdditive ? NSPoint(x: -q.x, y: -q.y) : NSPoint(x: m.x - (q.x - r.x), y: m.y - (q.y - r.y)))
            case ("position.x", let n as NSNumber):
                return NSNumber(value: copy.isAdditive ? -n.doubleValue : Double(m.x) - (n.doubleValue - Double(r.x)))
            case ("position.y", let n as NSNumber):
                return NSNumber(value: copy.isAdditive ? -n.doubleValue : Double(m.y) - (n.doubleValue - Double(r.y)))
            default:
                return v
            }
        }
        if let k = copy as? CAKeyframeAnimation {
            k.values = k.values?.map { flip($0) ?? $0 }
            if k.path != nil { return nil }  // a path flight: not inverted
        } else if let b = copy as? CABasicAnimation {
            b.fromValue = flip(b.fromValue)
            b.toValue = flip(b.toValue)
            if let by = b.byValue {
                switch (path, by) {
                case ("position", let p as NSValue): b.byValue = NSValue(point: NSPoint(x: -p.pointValue.x, y: -p.pointValue.y))
                case (_, let n as NSNumber): b.byValue = NSNumber(value: -n.doubleValue)
                default: return nil
                }
            }
        } else {
            return nil  // a spring or another kind: not inverted
        }
        return copy
    }

    /// The thread view's open state, followed after the engine changes that matter: the avatar dims with
    /// it, and the rows' masks follow while it is open or its rows remain.
    func followThread(open: Bool) {
        paneHeader.avatarOverlay.setDimmed(open)
        veilOpen = open
        clipThreadToHeader()
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
