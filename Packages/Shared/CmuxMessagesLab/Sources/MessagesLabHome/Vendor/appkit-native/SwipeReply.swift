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
/// transcript). A local event monitor holds a gesture that starts over a
/// message until its first few points of motion show the direction: a swipe to
/// the right, near horizontal, is claimed (none of its events, momentum
/// included, reach the scroll view); anything else is handed to the window in
/// order, so the scroll view scrolls it as if nothing had looked. A gesture
/// that starts anywhere else is never held.
///
/// cmux: motion fitted to the lossless 120 Hz references
/// (references/real-messages/interactions/swipe-*): 15 pt of slop, then 1:1,
/// then a rubber band to about 55 pt; the arrow waits under the bubble's start
/// and shows as the bubble slides off it.
final class SwipeReply {
    /// cmux: constants (`let`): nothing tunes them at run time.
    enum Tuning {
        /// Finger travel (pt) at which the reply arms.
        static let threshold: CGFloat = 60
        /// Finger travel before the row moves (measured 15 pt), then the row follows 1:1.
        static let slop: CGFloat = 15
        static let follow: CGFloat = 1
        /// cmux: past the threshold the row rubber-bands toward `stretch` more points; `stretchRate`
        /// is its slope there (swipe-full: 51 pt of offset at 115 pt of travel, 55 pt at 160).
        static let stretch: CGFloat = 14
        static let stretchRate: CGFloat = 0.25
        /// The row never moves further than this (pt).
        static let maxOffset: CGFloat = 110
        /// cmux: the arrow's centre sits this far right of the bubble's resting left edge, under the
        /// bubble until it slides away (swipe-full: still over the start while the bubble moves).
        static let arrowInset: CGFloat = 13
        static let arrowSize: CGFloat = 28
        /// Return to rest (measured: 25 pt back to 0 in 0.23 s, remaining fraction
        /// (1 - t/T)^1.6, within 1 px of every 120 Hz reference frame).
        static let returnDuration: CFTimeInterval = 0.23
        static let returnPower: Double = 1.6
        /// cmux: motion (pt) that decides a held gesture: claimed as a swipe or handed to the scroll view.
        static let decideDistance: CGFloat = 3
        /// cmux: a swipe moves right at least this many times as far as it moves up or down
        /// (within about 27 degrees of horizontal); a scroll that drifts sideways stays a scroll.
        static let axisRatio: CGFloat = 2
        /// cmux: a flick: released while moving at least `flickSpeed` (pt/s over the last
        /// `flickWindow` s) after at least `flickTravel` of travel also opens the reply.
        static let flickSpeed: CGFloat = 600
        static let flickTravel: CGFloat = 35
        static let flickWindow: TimeInterval = 0.05
    }

    private weak var c: ChatController?
    private var monitor: Any?
    /// cmux: the gesture's events held while its direction is unknown (may-begin, began, the first
    /// changes), in order, with their summed motion; `deciding` while any are held.
    private var held: [NSEvent] = []
    private var heldDX: CGFloat = 0
    private var heldDY: CGFloat = 0
    private var deciding = false
    private var claimed = false
    private var swallowMomentum = false
    private var travel: CGFloat = 0
    private var armed = false
    /// cmux: the claimed gesture's recent motion (event time, dx), for the release speed.
    private var recent: [(t: TimeInterval, dx: CGFloat)] = []
    private var hit: MessagesWindowView.Hit?
    private weak var cell: RowCell?
    private let arrow = CALayer()
    private var testPoint: CGPoint?
    /// cmux: Reduce Motion: the row still follows the fingers, but goes back without an animation.
    var reduceMotion: () -> Bool = { MessagesLabHomeView.reducesMotion }
    var rowOffset: CGFloat { cell.map { $0.layer.sublayerTransform.m41 } ?? 0 }

    init(controller: ChatController) {
        c = controller
        arrow.contentsGravity = .resizeAspect
        arrow.opacity = 0
    }

    /// Removes the event monitor (the sidebar replaces the transcript's controller).
    func uninstall() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            // Not `self?.handle(e) ?? e`: that turns a consumed event (nil) back into e.
            guard let self else { return e }
            return self.monitored(e)
        }
    }

    /// cmux: the monitor's answer for one event (nil: taken, the scroll view never sees it);
    /// `HomeSwipeReplyTests` feeds phased streams through it.
    func monitored(_ e: NSEvent, at: CGPoint? = nil) -> NSEvent? { handle(e, at: at) }

    /// Returns nil when the event is consumed.
    /// `at`: a host point for the check (`--swipe-check`, tests), whose events have no window.
    @discardableResult
    func handle(_ e: NSEvent, at: CGPoint? = nil) -> NSEvent? {
        testPoint = at
        guard let c, at != nil || e.window === c.window else { return e }
        // cmux: momentum belongs to the gesture before it: swallowed after a claimed swipe only.
        if !e.momentumPhase.isEmpty {
            guard swallowMomentum else { return e }
            if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return nil
        }
        // cmux: fingers down (may-begin), or a began with no may-begin before it, starts a gesture.
        // It is held only when it starts on a message of this pane. Held, the scroll view does not
        // start responsive scrolling, which would read the rest of the gesture on its own thread
        // (this monitor would never see it).
        if e.phase.contains(.mayBegin) || (e.phase.contains(.began) && !deciding) {
            reset()
            guard startsOnMessage(at: point(of: e)) else { return e }
            deciding = true
        }
        if deciding {
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                // Lifted (or a may-begin cancelled) before a direction: the scroll view gets it all.
                deciding = false
                handBack()
                return e
            }
            held.append(e)
            heldDX += e.scrollingDeltaX
            heldDY += e.scrollingDeltaY
            guard hypot(heldDX, heldDY) >= Tuning.decideDistance else { return nil }
            deciding = false
            if claim() { held = []; return nil }
            // Not a swipe: the held start goes to the window first (not through NSApp, so this
            // monitor does not see it again), then this event as usual.
            held.removeLast()
            handBack()
            return e
        }
        guard claimed else { return e }
        if e.phase.contains(.changed) { move(by: e.scrollingDeltaX, at: e.timestamp); return nil }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            end(cancelled: e.phase.contains(.cancelled), at: e.timestamp)
            return nil
        }
        return nil
    }

    /// cmux: a host point for an event.
    private func point(of e: NSEvent) -> CGPoint? {
        testPoint ?? c?.host.convert(e.locationInWindow, from: nil)
    }

    /// cmux: a new gesture starts over: a swipe still claimed (its release never came) ends
    /// cancelled, held events go back, the last swipe's momentum is no longer awaited, and the
    /// direction is decided on this gesture's motion alone (a claim keeps the sums it decided on).
    private func reset() {
        if claimed { end(cancelled: true, at: nil) }
        if deciding { handBack() }
        held = []
        heldDX = 0
        heldDY = 0
        deciding = false
        swallowMomentum = false
    }

    /// cmux: sends the held events to the window, in order (none in a check, whose events have no window).
    private func handBack() {
        let events = held
        held = []
        heldDX = 0
        heldDY = 0
        guard testPoint == nil, let window = c?.window else { return }
        events.forEach { window.sendEvent($0) }
    }

    /// cmux: a gesture may become a swipe: it starts on a message row of this (visible) pane.
    private func startsOnMessage(at p: CGPoint?) -> Bool {
        guard let c, let p, let demo = c.demo, !demo.threadOpen, c.picker == nil,
              !c.host.isHiddenOrHasHiddenAncestor, c.host.bounds.contains(p) else { return false }
        // Over a wide code block or table the gesture scrolls the block (MarkdownInput), not a reply.
        guard !demo.markdownScrollable(at: p), let h = demo.hit(p), visibleCell(h.key) != nil else { return false }
        hit = h
        return true
    }

    private func visibleCell(_ key: String) -> RowCell? {
        c?.demo?.collection.visibleCells.compactMap { $0 as? RowCell }.first { $0.spec?.key == key }
    }

    /// Claims the held gesture when it moves right, near horizontal, from a message.
    private func claim() -> Bool {
        guard let c, let h = hit, heldDX > 0, heldDX >= Tuning.axisRatio * abs(heldDY),
              let cell = visibleCell(h.key) else { hit = nil; return false }
        claimed = true
        self.cell = cell
        armed = false
        recent = held.map { (t: $0.timestamp, dx: $0.scrollingDeltaX) }
        // A swipe that starts while the row is still going back picks it up where it shows.
        travel = Self.travel(forOffset: cell.layer.presentation()?.sublayerTransform.m41 ?? 0)
        cell.layer.removeAnimation(forKey: "swipe.back")
        arrow.removeAllAnimations()
        // cmux: a pane's controller has an optional window.
        arrow.contents = Self.arrowImage(scale: c.window?.backingScaleFactor ?? DisplayScale.current)
        arrow.contentsScale = c.window?.backingScaleFactor ?? DisplayScale.current
        // Under the row's content: the bubble covers the arrow until it slides off it.
        cell.layer.insertSublayer(arrow, at: 0)
        apply(dx: heldDX)
        return true
    }

    /// Row offset for a finger travel. Real Messages (swipe-partial and swipe-full references):
    /// the row stays still for the first 15 pt of travel, then follows 1:1 up to the threshold,
    /// then rubber-bands toward `stretch` more points; capped at `maxOffset`.
    static func offset(_ travel: CGFloat) -> CGFloat {
        let t = max(0, travel - Tuning.slop) * Tuning.follow, th = max(0, Tuning.threshold - Tuning.slop) * Tuning.follow
        guard t > th else { return min(t, Tuning.maxOffset) }
        let x = t - th, s = Tuning.stretch
        let band = s > 0 ? s * (1 - 1 / (x * Tuning.stretchRate / s + 1)) : 0
        return min(th + band, Tuning.maxOffset)
    }

    /// cmux: the travel that shows `offset` (inverse of ``offset(_:)`` up to the threshold; past it, the threshold).
    static func travel(forOffset o: CGFloat) -> CGFloat {
        guard o > 0, Tuning.follow > 0 else { return 0 }
        return min(Tuning.slop + o / Tuning.follow, Tuning.threshold)
    }

    private func move(by dx: CGFloat, at t: TimeInterval) {
        recent.append((t: t, dx: dx))
        if recent.count > 32 { recent.removeFirst(recent.count - 32) }
        apply(dx: dx)
    }

    private func apply(dx: CGFloat) {
        travel += dx
        guard let cell = currentCell(), let spec = cell.spec else { return }
        let o = Self.offset(travel)
        let body = RowDraw.bodyRect(spec)
        let progress = min(1, o / Self.offset(Tuning.threshold))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cell.layer.sublayerTransform = CATransform3DMakeTranslation(o, 0, 0)
        // The arrow is a sublayer, so the row's translation moves it too; placed at `-o` it stays
        // over the bubble's resting start and fades in as the bubble uncovers it.
        let s = Tuning.arrowSize
        arrow.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        arrow.position = CGPoint(x: body.minX + Tuning.arrowInset - o, y: body.midY)
        arrow.opacity = Float(progress * progress)
        let scale = 0.8 + 0.2 * progress
        arrow.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        let nowArmed = travel >= Tuning.threshold
        if nowArmed && !armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        armed = nowArmed
    }

    /// cmux: the swiped message's cell. A transcript update during the swipe (a streaming reply)
    /// can hand the cell to another row: the offset and the arrow follow the message.
    private func currentCell() -> RowCell? {
        guard let key = hit?.key else { return nil }
        if let cell, cell.spec?.key == key { return cell }
        let old = cell
        let now = visibleCell(key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        old?.layer.sublayerTransform = CATransform3DIdentity
        if let now { now.layer.insertSublayer(arrow, at: 0) } else { arrow.removeFromSuperlayer() }
        CATransaction.commit()
        cell = now
        return now
    }

    /// cmux: speed (pt/s) over the last `flickWindow` before `t`.
    private func releaseSpeed(at t: TimeInterval) -> CGFloat {
        let from = t - Tuning.flickWindow
        let dx = recent.filter { $0.t >= from && $0.t <= t }.reduce(0) { $0 + $1.dx }
        return dx / CGFloat(Tuning.flickWindow)
    }

    /// cmux: the row's way back to rest from `x0`, as Messages (fitted keyframes, no overshoot).
    static func returnAnimation(from x0: CGFloat) -> CAKeyframeAnimation {
        let back = CAKeyframeAnimation(keyPath: "sublayerTransform")
        let n = 24
        back.values = (0...n).map { i -> NSValue in
            let f = pow(1 - Double(i) / Double(n), Tuning.returnPower)
            return NSValue(caTransform3D: CATransform3DMakeTranslation(x0 * CGFloat(f), 0, 0))
        }
        back.duration = Tuning.returnDuration
        back.calculationMode = .linear
        return back
    }

    private func end(cancelled: Bool, at t: TimeInterval?) {
        claimed = false
        swallowMomentum = true
        let flick = t.map { travel >= Tuning.flickTravel && releaseSpeed(at: $0) >= Tuning.flickSpeed } ?? false
        let opens = !cancelled && (armed || flick)
        if let cell {
            let x0 = cell.layer.sublayerTransform.m41
            let reduce = reduceMotion()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cell.layer.sublayerTransform = CATransform3DIdentity
            CATransaction.commit()
            if !reduce, x0 != 0 { cell.layer.add(Self.returnAnimation(from: x0), forKey: "swipe.back") }
            // The arrow fades out with the row's return, then leaves the cell (unless a new swipe took it).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self, arrow] in if self?.claimed == false { arrow.removeFromSuperlayer() } }
            if !reduce {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = arrow.opacity
                fade.toValue = 0
                fade.duration = 0.15
                arrow.add(fade, forKey: "fade")
            }
            arrow.opacity = 0
            CATransaction.commit()
        }
        if opens, let ref = hit?.row.ref, let c {
            if flick && !armed { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            c.dispatch(.reply(ref))
            c.focusCompose()
        }
        armed = false
        hit = nil
        recent = []
    }

    private static var arrowCache: [CGFloat: CGImage] = [:]
    static func arrowImage(scale: CGFloat) -> CGImage? {
        if let i = arrowCache[scale] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: Tuning.arrowSize * 0.7, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(white: 0.6, alpha: 1)]))
        guard let sym = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let px = CrashGuard.int(Tuning.arrowSize * scale, in: 1...4_096) // cmux: no trap on NaN
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
/// 1. short swipe (40 pt): 15 pt of slop, then the row follows 1:1, released it springs back, no reply.
/// 2. full swipe (160 pt): the row is capped, released it opens the reply (thread).
/// 3. vertical stream on the row: not claimed (the scroll view gets it).
enum SwipeCheck {
    static func fromArguments() -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--swipe-check") else { return nil }
        return a.dropFirst(i + 1).first // cmux: no index math
    }
    // cmux: optional, no force unwraps (crash program); `run` records a FAIL for a nil event.
    static func event(dx: CGFloat, dy: CGFloat, phase: Int64) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(clamping: CrashGuard.int(dy)), wheel2: Int32(clamping: CrashGuard.int(dx)), wheel3: 0) /* cmux: no trap on NaN or a huge delta */ else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(truncatingIfNeeded: CrashGuard.int(dy))) /* cmux: Int is 64-bit */
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(truncatingIfNeeded: CrashGuard.int(dx))) /* cmux */
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)
    }
    static func run(_ c: ChatController, out: String) {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { lines.append("\(ok ? "PASS" : "FAIL") \(name): \(detail)") }
        guard let hit = c.demo?.lastTextRow(mine: false) else { lines.append("FAIL no incoming text row"); finish(lines, out); return }
        let p = CGPoint(x: hit.body.midX, y: hit.body.midY)
        @discardableResult func handle(_ e: NSEvent?) -> NSEvent? { // cmux: a nil event is a FAIL, not a trap
            guard let e else { lines.append("FAIL could not make a scroll event"); return nil }
            return c.swipe.handle(e, at: p)
        }
        func stream(_ dx: CGFloat, _ dy: CGFloat, steps: Int) -> [CGFloat] {
            var offsets: [CGFloat] = []
            handle(event(dx: 0, dy: 0, phase: 128))   // may-begin, as a trackpad sends
            handle(event(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), phase: 1))
            for _ in 1..<steps { handle(event(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), phase: 2)); offsets.append(c.swipe.rowOffset) }
            return offsets
        }
        let short = stream(40, 0, steps: 8)
        check("short swipe: 15 pt slop, then 1:1 (25 pt after 40 pt)", abs((short.last ?? 0) - 25) < 0.5, "offset after 40 pt travel = \(short.last ?? -1)")
        handle(event(dx: 0, dy: 0, phase: 4))
        check("short swipe opens nothing", c.store?.state.ui.openThread == nil, "openThread = \(String(describing: c.store?.state.ui.openThread))")
        check("short swipe springs back (model)", c.swipe.rowOffset == 0, "model offset \(c.swipe.rowOffset)")
        let full = stream(160, 0, steps: 16)
        check("full swipe capped", (full.max() ?? 0) <= SwipeReply.Tuning.maxOffset + 0.01, "max offset \(full.max() ?? -1)")
        handle(event(dx: 0, dy: 0, phase: 4))
        check("full swipe opens the reply", c.store?.state.ui.openThread != nil, "openThread = \(String(describing: c.store?.state.ui.openThread))")
        c.dispatch(.closeThread)
        handle(event(dx: 0, dy: 0, phase: 128))
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
