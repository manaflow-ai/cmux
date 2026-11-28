#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A damped spring in UIKit's parametrisation: mass 1, stiffness
/// (2 pi / duration)^2, damping 4 pi (1 - bounce) / duration (for bounce >= 0;
/// 4 pi / (duration (1 + bounce)) below zero, as SwiftUI and UIKit define it).
struct Spring: Equatable {
    var duration: Double
    var bounce: Double
    var initialVelocity: Double = 0

    var mass: Double { 1 }
    var stiffness: Double { pow(2 * .pi / duration, 2) }
    var damping: Double { bounce >= 0 ? 4 * .pi * (1 - bounce) / duration : 4 * .pi / (duration * (1 + bounce)) }

    /// Progress 0 -> 1 at `tau` seconds after the start (closed form).
    func progress(_ tau: Double) -> Double {
        Spring.progress(tau, mass: mass, stiffness: stiffness, damping: damping, velocity: initialVelocity)
    }

    /// Closed form of a mass-spring-damper from 0 to 1, as CASpringAnimation
    /// runs it (initial velocity in units of the full distance per second).
    static func progress(_ tau: Double, mass m: Double, stiffness k: Double, damping c: Double, velocity v0: Double) -> Double {
        guard tau > 0 else { return 0 }
        let w0 = (k / m).squareRoot()
        let zeta = c / (2 * (k * m).squareRoot())
        let x0 = -1.0
        let x: Double
        if zeta < 1 - 1e-9 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            x = exp(-zeta * w0 * tau) * (x0 * cos(wd * tau) + (v0 + zeta * w0 * x0) / wd * sin(wd * tau))
        } else if zeta <= 1 + 1e-9 {
            x = exp(-w0 * tau) * (x0 + (v0 + w0 * x0) * tau)
        } else {
            let s = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - s), r2 = -w0 * (zeta + s)
            let c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2
            x = c1 * exp(r1 * tau) + c2 * exp(r2 * tau)
        }
        return 1 + x
    }

    /// Time after which the motion stays within `epsilon` (fraction of the distance).
    private struct SettleKey: Hashable { var d, b, v, e: Double }
    private static var settleCache: [SettleKey: Double] = [:]
    private static let settleLock = NSLock()
    /// Cached: every animation commit asks for it, and the search below runs
    /// up to 960 closed-form evaluations.
    func settlingTime(epsilon: Double = 2e-4) -> Double {
        let k = SettleKey(d: duration, b: bounce, v: initialVelocity, e: epsilon)
        Spring.settleLock.lock()
        if let v = Spring.settleCache[k] { Spring.settleLock.unlock(); return v }
        Spring.settleLock.unlock()
        let v = searchSettlingTime(epsilon: epsilon)
        Spring.settleLock.lock(); Spring.settleCache[k] = v; Spring.settleLock.unlock()
        return v
    }
    private func searchSettlingTime(epsilon: Double) -> Double {
        var t = 4.0
        // Walk back from a safe bound to the last time the error exceeds epsilon.
        let step = 1.0 / 240
        while t > 0, abs(1 - progress(t)) < epsilon { t -= step }
        return min(4, t + step)
    }
}

/// A cubic timing curve, as `CAMediaTimingFunction(controlPoints:)` with a
/// fixed duration. Some transitions of the real app fit a timing curve better
/// than any spring (see TRANSITIONS.md); they are committed as additive
/// `CABasicAnimation`s, on the render server like the springs.
struct Curve: Equatable {
    var x1, y1, x2, y2: Double
    var duration: Double

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
    /// Progress 0 -> 1 at `tau` seconds after the start.
    func progress(_ tau: Double) -> Double {
        guard tau > 0 else { return 0 }
        guard tau < duration else { return 1 }
        return Curve.solve(tau / duration, x1, y1, x2, y2)
    }
    /// y(s) where x(s) = u for the cubic Bezier (0,0) (x1,y1) (x2,y2) (1,1).
    /// Control points are clamped to [0, 1], as Core Animation does (a fitted
    /// y2 of 1.065 overshot in the closed form but not on screen: 0.25 pt).
    static func solve(_ u: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let c = { (v: Double) in min(1, max(0, v)) }
        let x1 = c(x1), y1 = c(y1), x2 = c(x2), y2 = c(y2)
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        // x(s) is monotonic for 0 <= x1, x2 <= 1: bisection, 40 steps (2^-40).
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 { let m = (lo + hi) / 2; if bx(m) < u { lo = m } else { hi = m } }
        return by((lo + hi) / 2)
    }
}

/// One fitted element of springs.json: `from + sum_i delta_i * p_i(t - delay_i)`,
/// where each `p_i` is a spring or, when `curve` is set, a timing curve.
struct SpringElement {
    struct Component {
        var delay: Double
        var spring: Spring
        var delta: Double
        var curve: Curve? = nil
        func progress(_ tau: Double) -> Double { curve?.progress(tau) ?? spring.progress(tau) }
        var activeTime: Double { curve?.duration ?? spring.settlingTime() }
    }
    var name: String
    var from: Double
    var to: Double
    var components: [Component]
    /// For a move: each component's share of the distance. A pulse (from == to)
    /// keeps its fitted deltas.
    var isPulse: Bool { abs(to - from) < 1e-6 }
    func share(_ i: Int) -> Double {
        let total = components.reduce(0) { $0 + $1.delta }
        guard let component = components[checked: i] else { return 0 } // checked
        return abs(total) < 1e-9 ? 0 : component.delta / total
    }
    /// Value at `tau` after the event for a move from `a` to `b` (pulse: `a` plus the fitted deltas).
    func value(_ tau: Double, from a: Double, to b: Double) -> Double {
        var v = a
        for (i, c) in components.enumerated() {
            let d = isPulse ? c.delta : (b - a) * share(i)
            v += d * c.progress(tau - c.delay)
        }
        return v
    }
    var settleTime: Double { components.map { $0.delay + $0.activeTime }.max() ?? 0 }
    /// The same element, every component `s` seconds later (the same curve shape and name). A
    /// later component holds its start value from the begin time (`Animate.sampled` for a spring,
    /// `Animate.basic` for a curve), so no frame before the start shows the final value (live and
    /// paused trees).
    func delayed(by s: Double) -> SpringElement {
        guard s > 0 else { return self }
        var e = self
        e.components = components.map { var c = $0; c.delay += s; return c }
        return e
    }
}

/// springs.json, bundled. Every animated element of the app takes its timing
/// from here; nothing else defines a curve.
enum Springs {
    static let all: [String: SpringElement] = {
        // cmux: a package resource (the app's main bundle does not hold it).
        guard let url = Bundle.module.url(forResource: "springs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        var out: [String: SpringElement] = [:]
        for (name, e) in obj {
            let comps = (e["components"] as? [[String: Any]] ?? []).map { c in
                let duration = c["duration"] as? Double ?? 0.3
                let cp = c["curve"] as? [Double]
                return SpringElement.Component(delay: c["delay"] as? Double ?? 0,
                                               spring: Spring(duration: duration, bounce: c["bounce"] as? Double ?? 0,
                                                              initialVelocity: c["initialVelocity"] as? Double ?? 0),
                                               delta: c["delta"] as? Double ?? 0,
                                               curve: cp.flatMap { $0.count == 4 ? Curve(x1: $0[0], y1: $0[1], x2: $0[2], y2: $0[3], duration: duration) : nil }) // no force unwrap
            }
            out.updateValue(SpringElement(name: name, from: e["from"] as? Double ?? 0, to: e["to"] as? Double ?? 0, components: comps), forKey: name)
        }
        return out
    }()
    static func element(_ name: String) -> SpringElement {
        all[name] ?? SpringElement(name: name, from: 0, to: 1, components: [.init(delay: 0, spring: Spring(duration: 0.3, bounce: 0), delta: 1)])
    }
    static var send: SpringElement { element("transcript.send") }
    /// Delivered and Read: macOS 27 the shared TRUTH.md curve; macOS 26 its own fits on the original recording
    /// (`.macOS26`: with the shared curve the motion gate's parity got worse at Delivered and Read).
    static var delivered: SpringElement { osElement("transcript.delivered") }
    static var read: SpringElement { osElement("transcript.read") }
    static var typing: SpringElement { element("transcript.typing") }
    static var receive: SpringElement { element("transcript.receive") }
    /// The first inline reply to the last message: the rows above that new thread root make room for its
    /// change-of-thread gap (RowBuilder), from `threadRootDip` below their old place (lossless typing-unfocused-take1).
    static var receiveThreadRoot: SpringElement { element("transcript.receiveThreadRoot") }
    /// How far the rows above a new thread root drop on the arrival's first frame (pt; the gap above the root
    /// closes), before they rise with `receiveThreadRoot` (lossless typing-unfocused-take1: 881 -> 888 pt).
    static let threadRootDip: CGFloat = 7
    /// A received photo or video (lossless send-typed-media take: an ease-in-out move, the
    /// photo's opacity following it).
    static var receiveMedia: SpringElement { element("transcript.receiveMedia") }
    /// My tapback (lossless tapback-menu-heart-take1: the rows above the part move 27.5 pt
    /// 90 ms after our react commit, an ease-in-out of 0.29 s).
    static var tapback: SpringElement { element("transcript.tapback") }
    static func isMedia(_ p: Part) -> Bool {
        if case let .attachment(a) = p { return a.kind == "image" || a.kind == "video" }
        return false
    }
    /// An outgoing message that arrives from outside the field (another
    /// device, a script): no morph, no field collapse.
    static var insert: SpringElement { element("transcript.insert") }
    /// The send morph's right edge, width, center and scale: macOS 27 fits (lossless takes), and
    /// the macOS 26 fits (the macOS 26 original recording) where `ComposeMetrics.macOS26` says so.
    static var bubbleRight: SpringElement { osElement("bubble.right") }
    static var bubbleWidth: SpringElement { osElement("bubble.width") }
    static var bubbleCenterY: SpringElement { osElement("bubble.centerY") }
    static var bubbleScale: SpringElement { osElement("bubble.scale") }
    /// The send morph's elements for one send (macOS 27): after a draft that shrinks the field, the
    /// `.fieldShrink` fits (refit3, cx-3cb.6); after a 1-line draft, on macOS and Mac Catalyst the
    /// `.oneLineMac` fits (right, width, centerY, scale: fit7, cx-3cb bubble-refit), on iOS the `.oneLine`
    /// fits where they exist (`bubble.width`, `bubble.right`: refit4, ANIMATIONS.md section 1); else the elements above.
    /// macOS 26: the elements above. (gpui and rawmath read the base elements for every send.)
    struct Bubble {
        var right, width, centerY, scale, opacity: SpringElement
        init(fieldShrinks: Bool) {
            func e(_ n: String, _ base: SpringElement) -> SpringElement {
                guard !ComposeMetrics.macOS26 else { return base }
                // macOS 27, 1-line draft: the `.oneLineMac` fit (four elements, fit7 on the four 1-line
                // send references, ANIMATIONS.md section 1 "1-line seven-reference fit"). iOS keeps `.oneLine`.
                #if os(macOS) || targetEnvironment(macCatalyst)
                if !fieldShrinks, let mac = Springs.all[n + ".oneLineMac"] { return mac }
                #endif
                return Springs.all[n + (fieldShrinks ? ".fieldShrink" : ".oneLine")] ?? base
            }
            right = e("bubble.right", Springs.bubbleRight); width = e("bubble.width", Springs.bubbleWidth)
            centerY = e("bubble.centerY", Springs.bubbleCenterY); scale = e("bubble.scale", Springs.bubbleScale)
            opacity = e("bubble.opacity", Springs.bubbleOpacity)
        }
    }
    static func osElement(_ name: String) -> SpringElement {
        ComposeMetrics.macOS26 ? (all[name + ".macOS26"] ?? element(name)) : element(name)
    }
    static var bubbleOpacity: SpringElement { osElement("bubble.opacity") }
    static var fieldTop: SpringElement { element("field.top") }
    /// The send's phase (s, added to the send transaction's begin time): how far into its curves
    /// Messages' first send frame is, against ours. Messages' first send frame shows the send about
    /// 10 ms into every curve after a 1-line draft, and one frame later in its curves (about 21 ms)
    /// after a draft that shrinks the field; ours shows 14.3 ms (our first frame after the commit).
    /// Measured on the seven lossless macOS 27 send takes, the same in the flying bubble's four
    /// edges, the rows and the field top (tools/evidence/ANIMATIONS.md, section 1, "Send phase"):
    /// the field's shrink costs Messages one more frame before its first send frame while its
    /// animations' clock has started. macOS 26 (the original recording): none.
    static func sendPhase(fieldShrinks: Bool) -> Double {
        guard !ComposeMetrics.macOS26 else { return 0 }
        return fieldShrinks ? -0.0066 : 0
    }
    /// The transcript's own delay in a send (s, after the send's begin time, for the rows only). Live drop-free
    /// paired takes on cmux-lawrence-2 (tools/evidence/ANIMATIONS.md section 5 "rows-later"; rows phase with the
    /// anchor frame as the base, scroll.py phase_anchor): main's rows are ahead of Messages' by 13.0 ms after a
    /// 1-line draft and 6.6 ms after a draft that shrinks the field; a first delay of 9.0 / 4.0 ms moved them by
    /// 9.1 / 3.5 ms and left 4.0 / 3.0 ms. The flying bubble's width is 2-4 ms ahead in both and stays. The
    /// rows' moves, the fades and receipts of the rows the send changes, and an older bubble still flying in its
    /// row start this much later; the new bubble's flight and the field keep `sendPhase`. macOS 26: none.
    static func sendRowsDelay(fieldShrinks: Bool) -> Double {
        guard !ComposeMetrics.macOS26 else { return 0 }
        return fieldShrinks ? 0.007 : 0.013
    }
    static var fieldOpacity: SpringElement { element("field.opacity") }

    /// A single-spring element for small effects that the recording does not
    /// constrain (fades, pops); same physics, one component.
    static func simple(_ name: String, delay: Double = 0, duration: Double, bounce: Double = 0) -> SpringElement {
        SpringElement(name: name, from: 0, to: 1, components: [.init(delay: delay, spring: Spring(duration: duration, bounce: bounce), delta: 1)])
    }
    /// Effects measured in earlier rounds (receipt pop, typing pop, reply fade),
    /// expressed as springs.
    /// The typing bubble's appearance, macOS (lossless send-typed-take1, send-typed-media-take1,
    /// typing-unfocused-take1; tools/evidence/ANIMATIONS.md section 6): scale 0 -> 1 about
    /// `RowDraw.typingAnchor`, opacity 0 -> 1 (the row's content: bubble, dots and discs fade as one), and
    /// a drift of `typingDrift` (pt, window) to its place;
    /// time 0 = the insert's begin (the rows' `transcript.typing`).
    static var typingScale: SpringElement { element("typing.scale") }
    static var typingOpacity: SpringElement { element("typing.opacity") }
    static var typingDriftX: SpringElement { element("typing.driftX") }
    static var typingDriftY: SpringElement { element("typing.driftY") }
    static let typingDrift = CGPoint(x: 4.79, y: -7.66)
    /// The two tail discs (`RowDraw.typingDiscs`, large then small), macOS: each a layer of its own at its
    /// window place (not in the scaled bubble). Messages shows them from its first frames at 0.5 and 0.8 of
    /// their size, a few points right of and above their place, and moves them there in about 0.25 s while
    /// the bubble grows (lossless send-typed-media-take1, typing-unfocused-take1; ANIMATIONS.md section 6).
    /// Offsets in window pt; their opacity is the bubble's (`typingOpacity`, on the row's content).
    static let typingDiscFrom: [(x: Double, y: Double, scale: Double)] = [(2.531, -8.190, 0.496), (3.643, -10.700, 0.800)]
    static func typingDiscX(_ i: Int) -> SpringElement { element(i == 0 ? "typing.discL.x" : "typing.discS.x") }
    static func typingDiscY(_ i: Int) -> SpringElement { element(i == 0 ? "typing.discL.y" : "typing.discS.y") }
    static func typingDiscScale(_ i: Int) -> SpringElement { element(i == 0 ? "typing.discL.scale" : "typing.discS.scale") }
    /// The dots' pulse phase (Cell.startTypingDots) starts this long after the insert's begin.
    static let typingDotsPhase = 0.05
    /// One breathing wave of the typing indicator (RowCell.breathe): an additive scale
    /// `amplitude` x (1 - cos(2 pi (t - start) / period)) / 2 from `start` (s after the insert's begin) on,
    /// repeating while the indicator shows: from its rest size (0) to 1 + amplitude and back.
    struct Breath { var amplitude: Double; var period: Double; var start: Double }
    /// Messages' typing indicator breathes while it shows, from the end of its appearance until the reply
    /// (lossless send-typed-media-take1 +4.94 s, 2.2 s at rest; typing-unfocused-take1, link-ask-instinct-take1
    /// and the 13 typing-dots stills agree; tools/evidence/ANIMATIONS.md section 6 "cx-3cb typing-breath"):
    /// three waves of their own, each from its rest size up and back, all at rest when the appearance ends.
    /// Large disc +10.6 % every 0.901 s, small disc +15.1 % every 0.700 s (each about its centre), the bubble
    /// with its dots +2.9 % every 1.906 s about `typingBreathAnchor`. When the reply comes, all three are
    /// at rest again on the arrival's first frame (RowCell.stopTypingBreath).
    static let typingBreathBody = Breath(amplitude: 0.0290, period: 1.906, start: 0.296)
    static let typingBreathDiscs = [Breath(amplitude: 0.1057, period: 0.901, start: 0.242),
                                    Breath(amplitude: 0.1510, period: 0.700, start: 0.178)]
    /// The point the bubble breathes about (row coordinates): 7.00 pt right of its left edge and 8.63 pt under its
    /// top (15.00 pt left of and 4.87 pt above its centre). Read from the pixel edges of every frame of the media
    /// take's 2.2 s at rest (tools/evidence/anim/typanchor.py, typanchorfit.py; ANIMATIONS.md section 6, cx-3cb
    /// typing-anchor): right +1.073 pt, top -0.271, bottom +0.552 at the peak. With this wave's +2.9 % the right edge
    /// gives x; y is the least-squares point of the top and bottom (their sum is 3.05 %: -0.250 and +0.533 here).
    /// Messages' left edge does not show its -0.20 pt: it clips the bubble to its frame rounded to whole device
    /// pixels (RowCell.clipTypingBody does the same). Before: 15.35 and 4.70 pt from the centre (a capsule fit with a
    /// blur bias; within this measurement's spread of about 1 pt, 0.03 pt at the edges).
    static var typingBreathAnchor: CGPoint {
        CGPoint(x: RowDraw.typingBubble.minX + 7.00, y: RowDraw.typingBubble.minY + 8.63)
    }
    /// `--typing-phase S` (still scenes only): the typing dots hold S s into their cycle and the breathing
    /// at rest (animation speed 0), so a still capture of the indicator is the same in every run.
    static let typingStillPhase: Double? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "--typing-phase") else { return nil }
        guard let v = a.dropFirst(i + 1).first.flatMap({ Double($0) }), v.isFinite else {
            FileHandle.standardError.write(Data("--typing-phase needs a finite number of seconds; the indicator animates\n".utf8))
            return nil
        }
        return v
    }()
    /// The iOS app's typing pop and receipt cross-fade (ios/Sources/ChatColumn.swift; the macOS
    /// transcript uses the fits above and below).
    static let typingPop = simple("typing.pop", delay: 0.05, duration: 0.209)
    static let typingFade = simple("typing.fade", delay: 0.05, duration: 0.12)
    static let receiptOldOut = simple("receipt.oldOut", delay: 0.042, duration: 0.163)   // fitted on luma, 6.55-7.25 s
    static let receiptNewIn = simple("receipt.newIn", delay: 0.262, duration: 0.243)    // fitted on luma, 6.55-7.25 s
    static let typingOut = simple("typing.out", delay: 0.02, duration: 0.2)
    static let receivedFade = simple("received.fade", delay: 0.2, duration: 0.2)
    /// Reply arrival, macOS (lossless send-typed-take1, send-typed-media-take1, typing-unfocused-take1;
    /// tools/evidence/ANIMATIONS.md section 3). A received text that is not a thread reply cross-fades
    /// with the typing bubble from the first frame; a thread reply first draws its connector at full
    /// opacity while the typing bubble fades (the same fade in both), then fades its bubble in.
    static var receivedTextFade: SpringElement { element("received.textFade") }
    static var typingOutOnReceive: SpringElement { element("typing.outOnReceive") }
    static var connectorDrawOnReceive: SpringElement { element("connector.drawOnReceive") }
    static var receivedThreadFade: SpringElement { element("received.threadFade") }
    static let receiptIn = simple("receipt.in", delay: 0.085, duration: 0.15)
    static let receiptPop = simple("receipt.pop", delay: 0.085, duration: 0.251)
    /// A receipt label that appears (Delivered) and one that changes its text (Delivered -> Read), macOS
    /// (lossless send-typed-take1, +1.04 s and +1.89 s; tools/evidence/ANIMATIONS.md section 7).
    static var receiptAppearOpacity: SpringElement { element("receipt.appearOpacity") }
    static var receiptAppearGrow: SpringElement { element("receipt.appearGrow") }
    static let receiptAppearScale: CGFloat = 0.3
    static var receiptChangeOut: SpringElement { element("receipt.changeOut") }
    static var receiptChangeIn: SpringElement { element("receipt.changeIn") }
    static let ghostOut = simple("row.out", delay: 0, duration: 0.2)
    /// The send overlay's fade over the landed cell (WindowView.landMorphs): live 120 Hz takes of main f0be76b
    /// (tools/live-motion, cx-3cb) showed the hand-off as ONE frame that changed every glyph edge of the landed
    /// balloon (send-typed #405: 10411 px, up to 180 levels, the frame before 1138 px); spread over ~12 frames.
    static let landFade = simple("land.fade", delay: 0, duration: 0.1)
    static let connectorDraw = simple("connector.draw", delay: 0, duration: 0.25)
    static let textUnblur = simple("text.unblur", delay: 0.035, duration: 0.12)
    static let fieldGrow = simple("field.grow", delay: 0, duration: 0.1)
    static let scrollToBottom = simple("scroll.bottom", delay: 0, duration: 0.45, bounce: 0)
}

/// Adds additive spring animations. The model value is already the final
/// value; each component animates `-delta_i -> 0`, so the presented value is
/// `final + sum_i delta_i (p_i(t) - 1)`, which equals the fitted element.
/// Further animations on the same key path add up (no snap on interruption).
enum Animate {
    /// Animations added so far (also the key serial; the bench counts animations per commit).
    private(set) static var serial = 0

    /// Local time of `layer` now (virtual time when the root is paused).
    static func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }

    /// Animate `keyPath` (a scalar sub key path such as "position.y",
    /// "bounds.size.width", "opacity", "transform.scale") from `from` to the
    /// model value `to` with `element`'s timing, starting at `begin`.
    @discardableResult
    static func scalar(_ layer: CALayer, _ keyPath: String, from: Double, to: Double, _ element: SpringElement,
                       begin: CFTimeInterval, delayShift: Double = 0) -> [String] {
        var keys: [String] = []
        for (i, c) in element.components.enumerated() {
            let d = element.isPulse ? c.delta : (to - from) * element.share(i)
            guard abs(d) > 1e-6 else { continue }
            if let curve = c.curve {
                keys.append(basic(layer, keyPath, delta: d, curve: curve, begin: begin + c.delay + delayShift, holdFrom: begin))
                continue
            }
            if c.delay + delayShift > 0 {
                // A component that starts later is committed as an additive
                // keyframe animation that starts now and samples the same
                // spring at 240 Hz (flat until its delay). The render server did
                // not hold `fillMode = .backwards` values for a spring whose
                // beginTime lay ahead in a paused (live-grab) tree.
                keys.append(sampled(layer, keyPath, delta: d, spring: c.spring, delay: c.delay + delayShift, begin: begin))
                continue
            }
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = c.spring.stiffness
            a.damping = c.spring.damping
            a.initialVelocity = c.spring.initialVelocity
            a.fromValue = -d
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + c.delay + delayShift
            a.duration = c.spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            serial += 1
            let key = "spring.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            keys.append(key)
        }
        return keys
    }

    /// The render server clamps opacity while it sums additive animations, so
    /// an opacity pulse whose components leave [0, 1] is committed as one
    /// keyframe animation sampled from the same closed form (240 Hz). Core
    /// Animation still interpolates it on the render server.
    /// `depth` scales the pulse's excursion from `base` (1: the fitted pulse).
    static func sampledPulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, base: Double, depth: Double = 1,
                             begin: CFTimeInterval) {
        let end = element.settleTime
        let n = max(2, CrashGuard.int(end * 240, in: 0...14_400)) // at most 60 s of samples, no trap on NaN
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (0...n).map {
            NSNumber(value: min(1, max(0, base + depth * (element.value(Double($0) / 240, from: base, to: base) - base))))
        }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        serial += 1
        layer.add(a, forKey: "sampled.\(keyPath).\(serial)")
    }

    /// An absolute keyframe opacity that follows a pulse element down to its
    /// lowest value and then stays at 0 (a surface that leaves with the
    /// pulse's fade-out and does not come back). Sampled at 240 Hz.
    static func sampledUntilMinimum(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, base: Double, begin: CFTimeInterval) {
        let n = max(2, CrashGuard.int(element.settleTime * 240, in: 0...14_400)) // at most 60 s, no trap on NaN
        let samples: [Double] = (0...n).map { min(1, max(0, element.value(Double($0) / 240, from: base, to: base))) }
        // zero from the lowest sample on, without index math.
        let low = samples.enumerated().min { $0.element < $1.element }?.offset ?? n
        let values = samples.enumerated().map { $0.offset >= low ? 0 : $0.element }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { NSNumber(value: $0) }
        a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        a.duration = Double(n) / 240
        a.beginTime = begin
        a.calculationMode = .linear
        a.fillMode = .backwards
        a.isRemovedOnCompletion = true
        serial += 1
        layer.add(a, forKey: "sampled.\(keyPath).\(serial)")
    }

    /// `--x-two-animation-springs`: the hold-and-spring form in live trees too (the before arm of
    /// the A/B bench of the one-animation form; animations per send).
    static let twoAnimationForm = ProcessInfo.processInfo.arguments.contains("--x-two-animation-springs")

    /// Whether `layer` is in a paused tree (an ancestor with speed 0: captures, checks, live grabs),
    /// where the render server did not hold a backward fill for a start that lay ahead. A layer
    /// with no superlayer (a mask, a detached layer) counts as paused: the two-animation form is
    /// right in both trees.
    static func inPausedTree(_ layer: CALayer) -> Bool {
        if twoAnimationForm { return true }
        var l = layer
        while let up = l.superlayer {
            if l.speed == 0 { return true }
            l = up
        }
        return l === layer || l.speed == 0
    }

    /// Model opacity for "hidden" layers that still animate: the render
    /// server skips layers whose model opacity is exactly 0, animations or not.
    static let hiddenOpacity: Float = 0.01

    /// A delayed spring component without per-sample boxing: an additive hold
    /// at -delta from `begin` to `begin + delay` (two values), then a real
    /// CASpringAnimation from -delta to 0 that starts exactly when the hold
    /// ends. The spring has no backward fill (a paused tree did not honour it),
    /// so the sum is continuous at the hand-over in live and paused trees.
    /// (The earlier 240 Hz keyframe path boxed 150-300 NSNumbers per row per
    /// send: 485k main-thread allocations in 20 fast sends.)
    static func sampled(_ layer: CALayer, _ keyPath: String, delta d: Double, spring: Spring, delay: Double, begin: CFTimeInterval) -> String {
        if !inPausedTree(layer) {
            // A live tree holds a backward fill (only a paused tree did not): one animation, not
            // a hold and a spring. The same presented values (Presenter evaluates both alike).
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = spring.stiffness
            a.damping = spring.damping
            a.initialVelocity = spring.initialVelocity
            a.fromValue = -d
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + delay
            a.duration = spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            serial += 1
            let key = "spring.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            return key
        }
        let hold = CAKeyframeAnimation(keyPath: keyPath)
        hold.values = [-d, -d]
        hold.beginTime = begin
        hold.duration = delay
        hold.isAdditive = true
        hold.fillMode = .backwards
        hold.isRemovedOnCompletion = true
        serial += 1
        layer.add(hold, forKey: "hold.\(serial)")
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = spring.stiffness
        a.damping = spring.damping
        a.initialVelocity = spring.initialVelocity
        a.fromValue = -d
        a.toValue = 0.0
        a.isAdditive = true
        a.beginTime = begin + delay
        a.duration = spring.settlingTime()
        a.isRemovedOnCompletion = true
        serial += 1
        let key = "spring.\(keyPath).\(serial)"
        layer.add(a, forKey: key)
        return key
    }

    /// A timing-curve component: an additive `CABasicAnimation` from -delta to
    /// 0. A start after `holdFrom` gets the same two-value hold as a delayed
    /// spring (no backward fill; a paused tree did not honour it).
    static func basic(_ layer: CALayer, _ keyPath: String, delta d: Double, curve: Curve, begin: CFTimeInterval,
                      holdFrom: CFTimeInterval) -> String {
        let live = begin > holdFrom && !inPausedTree(layer)
        if begin > holdFrom, !live {
            let hold = CAKeyframeAnimation(keyPath: keyPath)
            hold.values = [-d, -d]
            hold.beginTime = holdFrom
            hold.duration = begin - holdFrom
            hold.isAdditive = true
            hold.fillMode = .backwards
            hold.isRemovedOnCompletion = true
            serial += 1
            layer.add(hold, forKey: "hold.\(serial)")
        }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = -d
        a.toValue = 0.0
        a.timingFunction = curve.timingFunction
        a.isAdditive = true
        a.beginTime = begin
        a.duration = curve.duration
        if begin <= holdFrom || live { a.fillMode = .backwards }
        a.isRemovedOnCompletion = true
        serial += 1
        let key = "curve.\(keyPath).\(serial)"
        layer.add(a, forKey: key)
        return key
    }

    /// A pulse element (from == to) on a layer whose model value is unchanged.
    @discardableResult
    static func pulse(_ layer: CALayer, _ keyPath: String, _ element: SpringElement, scale: Double = 1, begin: CFTimeInterval) -> [String] {
        var keys: [String] = []
        for c in element.components {
            if let curve = c.curve {
                keys.append(basic(layer, keyPath, delta: c.delta * scale, curve: curve, begin: begin + c.delay, holdFrom: begin))
                continue
            }
            if c.delay > 0 {
                keys.append(sampled(layer, keyPath, delta: c.delta * scale, spring: c.spring, delay: c.delay, begin: begin))
                continue
            }
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = c.spring.stiffness
            a.damping = c.spring.damping
            a.initialVelocity = c.spring.initialVelocity
            a.fromValue = -c.delta * scale
            a.toValue = 0.0
            a.isAdditive = true
            a.beginTime = begin + c.delay
            a.duration = c.spring.settlingTime()
            a.fillMode = .backwards
            a.isRemovedOnCompletion = true
            // A pulse component is "delta * (p - 1)"; the components' deltas
            // sum to zero, so before the first start the sum is zero too.
            serial += 1
            let key = "pulse.\(keyPath).\(serial)"
            layer.add(a, forKey: key)
            keys.append(key)
        }
        return keys
    }
}

/// Closed-form evaluation of the animations in a layer tree at the layer's
/// local time. Capture uses it to render exact frames: it writes the presented
/// values into the model, renders, and restores the model.
enum Presenter {
    struct Saved { var layer: CALayer; var keyPath: String; var value: Any? }

    /// Presented minus model for one animation at local time `t` (nil: not active).
    static func contribution(_ anim: CAAnimation, at t: CFTimeInterval) -> (keyPath: String, delta: Double)? {
        if let s = anim as? CASpringAnimation, let kp = s.keyPath, s.isAdditive {
            let from = (s.fromValue as? NSNumber)?.doubleValue ?? 0, to = (s.toValue as? NSNumber)?.doubleValue ?? 0
            var tau = (t - s.beginTime) * Double(s.speed) + s.timeOffset
            if tau < 0 { if s.fillMode == .backwards || s.fillMode == .both { tau = 0 } else { return nil } }
            if tau > s.duration { return s.isRemovedOnCompletion ? nil : (kp, to) }
            let p = Spring.progress(tau, mass: s.mass, stiffness: s.stiffness, damping: s.damping, velocity: s.initialVelocity)
            return (kp, from + (to - from) * p)
        }
        if !(anim is CASpringAnimation), let b = anim as? CABasicAnimation, let kp = b.keyPath, b.isAdditive,
           let from = (b.fromValue as? NSNumber)?.doubleValue {
            let to = (b.toValue as? NSNumber)?.doubleValue ?? 0
            var tau = (t - b.beginTime) * Double(b.speed) + b.timeOffset
            if tau < 0 { if b.fillMode == .backwards || b.fillMode == .both { tau = 0 } else { return nil } }
            if tau > b.duration { return b.isRemovedOnCompletion ? nil : (kp, to) }
            var u = b.duration > 0 ? tau / b.duration : 1
            if let f = b.timingFunction {
                var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
                f.getControlPoint(at: 1, values: &p1); f.getControlPoint(at: 2, values: &p2)
                u = Curve.solve(u, Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
            }
            return (kp, from + (to - from) * u)
        }
        if let k = anim as? CAKeyframeAnimation, let kp = k.keyPath, let values = k.values as? [NSNumber], values.count > 1 {
            var tau = (t - k.beginTime) * Double(k.speed) + k.timeOffset
            if tau < 0 {
                // Backward fill shows the first value before the start, as the
                // render server does (the hold of a delayed component).
                guard k.fillMode == .backwards || k.fillMode == .both else { return nil }
                tau = 0
            }
            let total = k.duration * Double(max(1, k.repeatCount))
            if k.repeatCount < .infinity, tau >= total { return k.isRemovedOnCompletion ? nil : values.last.map { (kp, $0.doubleValue) } } // no force unwrap
            // Wrap only repeating animations (a one-shot at exactly its end
            // must not wrap to its first value).
            if k.repeatCount > 1 { tau = tau.truncatingRemainder(dividingBy: k.duration) }
            let u = tau / k.duration
            let times = (k.keyTimes ?? []).map(\.doubleValue)
            let ts = times.count == values.count ? times : values.indices.map { Double($0) / Double(values.count - 1) }
            // the first inner key time at or past u, else the last; checked reads.
            let i = ts.dropFirst().dropLast().firstIndex(where: { $0 >= u }) ?? max(1, ts.count - 1)
            guard let t0 = ts[checked: i - 1], let t1 = ts[checked: i], let v0 = values[checked: i - 1]?.doubleValue,
                  let v1 = values[checked: i]?.doubleValue else { return (kp, values.last?.doubleValue ?? 0) }
            let f = max(0, min(1, (u - t0) / max(1e-9, t1 - t0)))
            let v = v0 + (v1 - v0) * f
            return (kp, v)
        }
        return nil
    }

    /// Apply presented values at the root's local time to the whole tree.
    /// Returns what to restore.
    static func apply(_ root: CALayer) -> [Saved] {
        var saved: [Saved] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        visit(root, &saved)
        CATransaction.commit()
        return saved
    }

    private static func visit(_ layer: CALayer, _ saved: inout [Saved]) {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let t = now(layer)
            var sums: [String: Double] = [:]
            var absolute: [String: Double] = [:]
            for k in keys {
                guard let a = layer.animation(forKey: k), let (kp, d) = contribution(a, at: t) else { continue }
                if (a as? CAPropertyAnimation)?.isAdditive == true { sums[kp, default: 0] += d } else { absolute[kp] = d }
            }
            for (kp, v) in absolute { saved.append(Saved(layer: layer, keyPath: kp, value: layer.value(forKeyPath: kp))); layer.setValue(v, forKeyPath: kp) }
            for (kp, d) in sums where abs(d) > 1e-9 {
                if kp == "transform.scale" {
                    // render(in:) draws only affine transforms; "transform.scale"
                    // also scales z, so write the 2-D equivalent.
                    let cur = Double(layer.transform.m11)
                    saved.append(Saved(layer: layer, keyPath: "transform", value: layer.value(forKey: "transform")))
                    layer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(scaleX: CGFloat(cur + d), y: CGFloat(cur + d)))
                    continue
                }
                let cur = (layer.value(forKeyPath: kp) as? NSNumber)?.doubleValue ?? 0
                saved.append(Saved(layer: layer, keyPath: kp, value: layer.value(forKeyPath: kp)))
                layer.setValue(cur + d, forKeyPath: kp)
            }
        }
        layer.sublayers?.forEach { visit($0, &saved) }
    }

    static func restore(_ saved: [Saved]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in saved.reversed() { if s.keyPath == "transform" { s.layer.setValue(s.value, forKey: "transform") } else { s.layer.setValue(s.value, forKeyPath: s.keyPath) } }
        CATransaction.commit()
    }

    static func now(_ layer: CALayer) -> CFTimeInterval { layer.convertTime(CACurrentMediaTime(), from: nil) }
}
