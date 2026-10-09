import AppKit
import QuartzCore

/// Trackpad swipe-to-reply, as in Messages: a two-finger swipe to the right
/// on a message moves its row with the fingers and shows a reply arrow at its
/// left; released past the threshold it opens the reply (the shared
/// `.reply` action, the same path as Reply in the context menu) and the row
/// springs back. Short of the threshold it only springs back.
///
/// Input: the phased scroll stream (`scrollWheel` events with `phase`, then
/// `momentumPhase`), which is what the real app reacts to (probe on
/// cmux-lawrence-2: a posted phased horizontal scroll opens Messages' reply
/// transcript). A local event monitor claims a gesture whose first motion is
/// horizontal and starts over a message; every other gesture reaches the
/// scroll view untouched, so AppKit's responsive scrolling stays. The
/// gesture's momentum events are swallowed too.
///
/// Motion constants are placeholders until the 120 Hz reference
/// (references/real-messages/interactions/swipe-*) is fitted.
final class SwipeReply {
    enum Tuning {
        /// Finger travel (pt) at which the reply arms.
        static var threshold: CGFloat = 60
        /// Past the threshold the row follows with this resistance.
        static var resistance: CGFloat = 0.35
        /// The row never moves further than this (pt).
        static var maxOffset: CGFloat = 110
        /// The arrow's centre sits this far left of the bubble at rest (pt).
        static var arrowInset: CGFloat = 22
        static var arrowSize: CGFloat = 22
        /// Spring back (damping ratio 1: no overshoot).
        static var returnResponse: CFTimeInterval = 0.3
    }

    private weak var c: ChatController?
    private var monitor: Any?
    /// Gesture state.
    private var pending: NSEvent?
    private var claimed = false
    private var swallowMomentum = false
    private var travel: CGFloat = 0
    private var armed = false
    private var hit: MessagesWindowView.Hit?
    private weak var cell: RowCell?
    private let arrow = CALayer()
    private var testPoint: CGPoint?
    var rowOffset: CGFloat { cell.map { $0.layer.sublayerTransform.m41 } ?? 0 }

    init(controller: ChatController) {
        c = controller
        arrow.contentsGravity = .resizeAspect
        arrow.opacity = 0
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.handle(e) ?? e }
    }

    /// Returns nil when the event is consumed.
    /// `at`: a host point for the check (`--swipe-check`), whose events have no window.
    @discardableResult
    func handle(_ e: NSEvent, at: CGPoint? = nil) -> NSEvent? {
        testPoint = at
        guard let c, at != nil || e.window === c.window else { return e }
        if swallowMomentum, !e.momentumPhase.isEmpty {
            if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return nil
        }
        if e.phase.contains(.mayBegin) { return e }
        if e.phase.contains(.began) {
            claimed = false
            pending = nil
            let (dx, dy) = (e.scrollingDeltaX, e.scrollingDeltaY)
            if dx == 0 && dy == 0 { pending = e; return nil }   // decide on the first motion
            return begin(e) ? nil : e
        }
        if let held = pending {
            pending = nil
            // cmux: optional window (pane host).
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { if at == nil { c.window?.sendEvent(held) }; return e }
            if begin(e, start: held) { return nil }
            // A vertical gesture: deliver its held start to the window first (not
            // through NSApp, so this monitor does not see it again).
            if at == nil { c.window?.sendEvent(held) }  // cmux: optional window
            return e
        }
        guard claimed else { return e }
        if e.phase.contains(.changed) { move(by: e.scrollingDeltaX); return nil }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { end(cancelled: e.phase.contains(.cancelled)); return nil }
        return nil
    }

    /// Claims the gesture when its first motion is horizontal and starts over a message.
    private func begin(_ e: NSEvent, start: NSEvent? = nil) -> Bool {
        guard let c, let demo = c.demo, !demo.threadOpen, c.picker == nil else { return false }
        let (dx, dy) = (e.scrollingDeltaX, e.scrollingDeltaY)
        guard abs(dx) > abs(dy) else { return false }
        let p = testPoint ?? c.host.convert((start ?? e).locationInWindow, from: nil)
        guard let h = demo.hit(p),
              let cell = demo.collection.visibleCells.compactMap({ $0 as? RowCell }).first(where: { $0.spec?.key == h.key }) else { return false }
        claimed = true
        hit = h
        self.cell = cell
        travel = 0
        armed = false
        cell.layer.removeAnimation(forKey: "swipe.back")
        arrow.removeAllAnimations()
        // cmux: a pane's controller has an optional window.
        arrow.contents = Self.arrowImage(scale: c.window?.backingScaleFactor ?? DisplayScale.current)
        arrow.contentsScale = c.window?.backingScaleFactor ?? DisplayScale.current
        cell.layer.addSublayer(arrow)
        move(by: dx)
        return true
    }

    /// Row offset for a finger travel: 1:1 up to the threshold, then resisted, capped.
    static func offset(_ travel: CGFloat) -> CGFloat {
        let t = max(0, travel), th = Tuning.threshold
        let o = t <= th ? t : th + (t - th) * Tuning.resistance
        return min(o, Tuning.maxOffset)
    }

    private func move(by dx: CGFloat) {
        guard let cell, let spec = cell.spec else { return }
        travel += dx
        let o = Self.offset(travel)
        let body = RowDraw.bodyRect(spec)
        let progress = min(1, o / Tuning.threshold)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cell.layer.sublayerTransform = CATransform3DMakeTranslation(o, 0, 0)
        // The arrow is a sublayer, so it moves with the row; it is placed so that
        // it stays left of the bubble and slides in with the swipe.
        let s = Tuning.arrowSize
        arrow.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        arrow.position = CGPoint(x: body.minX - Tuning.arrowInset - o + o * 0.5, y: body.midY)
        arrow.opacity = Float(progress)
        let scale = 0.5 + 0.5 * progress
        arrow.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        let nowArmed = travel >= Tuning.threshold
        if nowArmed && !armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        armed = nowArmed
    }

    private func end(cancelled: Bool) {
        claimed = false
        swallowMomentum = true
        guard let cell else { return }
        let from = cell.layer.sublayerTransform
        cell.layer.sublayerTransform = CATransform3DIdentity
        let back = CASpringAnimation(keyPath: "sublayerTransform")
        back.fromValue = NSValue(caTransform3D: from)
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        back.mass = 1
        back.stiffness = pow(2 * .pi / Tuning.returnResponse, 2)
        back.damping = 4 * .pi / Tuning.returnResponse
        back.duration = back.settlingDuration
        cell.layer.add(back, forKey: "swipe.back")
        // The arrow fades out, then leaves the cell (unless a new swipe took it).
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, arrow] in if self?.claimed == false { arrow.removeFromSuperlayer() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = arrow.opacity
        fade.toValue = 0
        fade.duration = 0.15
        arrow.opacity = 0
        arrow.add(fade, forKey: "fade")
        CATransaction.commit()
        if armed && !cancelled, let ref = hit?.row.ref, let c {
            c.dispatch(.reply(ref))
            c.focusCompose()
        }
        armed = false
        hit = nil
    }

    private static var arrowCache: [CGFloat: CGImage] = [:]
    static func arrowImage(scale: CGFloat) -> CGImage? {
        if let i = arrowCache[scale] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: Tuning.arrowSize * 0.7, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(white: 0.6, alpha: 1)]))
        guard let sym = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let px = Int(Tuning.arrowSize * scale)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: LabColorSpace.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil } // cmux: no force unwrap
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let sz = sym.size, r = CGFloat(px)
        sym.draw(in: NSRect(x: (r - sz.width * scale) / 2, y: (r - sz.height * scale) / 2, width: sz.width * scale, height: sz.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()
        arrowCache[scale] = img
        return img
    }
}

/// `--swipe-check OUT` (headless): feeds phased scroll streams to the swipe
/// handler on the last incoming text row and checks the outcome.
/// 1. short swipe (40 pt): the row follows 1:1, released it springs back, no reply.
/// 2. full swipe (160 pt): the row is capped, released it opens the reply (thread).
/// 3. vertical stream on the row: not claimed (the scroll view gets it).
enum SwipeCheck {
    static func fromArguments() -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--swipe-check"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    // cmux: optional, no force unwraps (crash program); `run` records a FAIL for a nil event.
    static func event(dx: CGFloat, dy: CGFloat, phase: Int64) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)
    }
    static func run(_ c: ChatController, out: String) {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name): \(detail)") }
        guard let hit = c.demo.lastTextRow(mine: false) else { lines.append("FAIL no incoming text row"); finish(lines, out); return }
        let p = CGPoint(x: hit.body.midX, y: hit.body.midY)
        @discardableResult func handle(_ e: NSEvent?) -> NSEvent? { // cmux: a nil event is a FAIL, not a trap
            guard let e else { lines.append("FAIL could not make a scroll event"); return nil }
            return c.swipe.handle(e, at: p)
        }
        func stream(_ dx: CGFloat, _ dy: CGFloat, steps: Int) -> [CGFloat] {
            var offsets: [CGFloat] = []
            handle(event(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), phase: 1))
            for _ in 1..<steps { handle(event(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), phase: 2)); offsets.append(c.swipe.rowOffset) }
            return offsets
        }
        let short = stream(40, 0, steps: 8)
        check("short swipe follows 1:1", abs((short.last ?? 0) - 40) < 0.5, "offset after 40 pt travel = \(short.last ?? -1)")
        handle(event(dx: 0, dy: 0, phase: 4))
        check("short swipe opens nothing", c.store.state.ui.openThread == nil, "openThread = \(String(describing: c.store.state.ui.openThread))")
        check("short swipe springs back (model)", c.swipe.rowOffset == 0, "model offset \(c.swipe.rowOffset)")
        let full = stream(160, 0, steps: 16)
        check("full swipe capped", (full.max() ?? 0) <= SwipeReply.Tuning.maxOffset + 0.01, "max offset \(full.max() ?? -1)")
        handle(event(dx: 0, dy: 0, phase: 4))
        check("full swipe opens the reply", c.store.state.ui.openThread != nil, "openThread = \(String(describing: c.store.state.ui.openThread))")
        c.dispatch(.closeThread)
        let consumedVertical = handle(event(dx: 0, dy: -20, phase: 1)) == nil
        handle(event(dx: 0, dy: 0, phase: 4))
        check("vertical stream not claimed", !consumedVertical, "consumed = \(consumedVertical)")
        finish(lines, out)
    }
    static func finish(_ lines: [String], _ out: String) {
        let fails = lines.filter { $0.hasPrefix("FAIL") }.count
        let text = lines.joined(separator: "\n") + "\n\(lines.count - fails) of \(lines.count) pass\n"
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
        print(text)
        exit(fails == 0 ? 0 : 1)
    }
}
