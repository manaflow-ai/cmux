#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextDesignTokens
public import Foundation
public import QuartzCore

/// CLOSE VARIANTS film selector (cmux-ad m57, task close-variants): which pane-close motion a film shows, so Lawrence can
/// compare them side by side and pick one. DEBUG and bench builds only; it never ships. Branch
/// close-variants/film-selector-nomerge only: never merged, never a PR. After the pick, the winner lands with no selector.
///
/// Set by the film harness: the launch variables `CMUX_FILM_CLOSE_VARIANT` (V0, V1, V2, V2b, V3, V4, V5),
/// `CMUX_FILM_CLOSE_MS` (default 150) and `CMUX_FILM_CLOSE_CURVE` (bezier, spring), or at run time
/// `debug.frames {"action": "close_variant V3 150 bezier"}` (``select(_:)``).
public struct FilmCloseVariant: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The current close: the survivors grow on the spring (reference).
        case v0 = "V0"
        /// Instant: the survivors show at their final size in the next frame, the closed pane is gone.
        case v1 = "V1"
        /// Reveal (not built yet: plays as V0).
        case v2 = "V2"
        /// Reveal anchored to the moving edge (not built yet: plays as V0).
        case v2b = "V2b"
        /// Cover-out: the survivors at their final size at once; the closed pane's last picture slides out on top.
        case v3 = "V3"
        /// Fade-out: the survivors at their final size at once; the closed pane's last picture fades out on top.
        case v4 = "V4"
        /// V3 and V4 together.
        case v5 = "V5"
        /// Grow + fade (cmux-ad m67): the survivors grow on the curve and the closed pane's last picture, above them in
        /// place, fades out on the same progress (one value, one curve; a spring's opacity clamped to 0...1).
        case v6 = "V6"
    }

    public enum Curve: String, Sendable {
        /// cubic-bezier(0.2, 0, 0, 1), ease-out.
        case bezier
        /// A critically damped spring (no overshoot) that settles in the duration.
        case spring
    }

    /// A named curve of the CURVE SET (cmux-ad m63, Lawrence: "i want to see a bunch of different curves, maybe springs,
    /// faster"): K1-K5 and K10 are timed beziers, K6-K9 springs (response, damping fraction; SwiftUI semantics, mass 1).
    public enum Shape: Sendable, Equatable {
        case bezier(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double)
        case spring(response: Double, damping: Double)

        public static let named: [String: Shape] = [
            "K1": .bezier(x1: 0.2, y1: 0, x2: 0, y2: 1, seconds: 0.08),
            "K2": .bezier(x1: 0.2, y1: 0, x2: 0, y2: 1, seconds: 0.1),
            "K3": .bezier(x1: 0.2, y1: 0, x2: 0, y2: 1, seconds: 0.12),
            "K4": .bezier(x1: 0.22, y1: 1, x2: 0.36, y2: 1, seconds: 0.1),
            "K5": .bezier(x1: 0.65, y1: 0, x2: 0.35, y2: 1, seconds: 0.12),
            "K6": .spring(response: 0.15, damping: 1),
            "K7": .spring(response: 0.18, damping: 0.9),
            "K8": .spring(response: 0.2, damping: 0.8),
            "K9": .spring(response: 0.25, damping: 0.7),
            "K10": .bezier(x1: 0, y1: 0, x2: 1, y2: 1, seconds: 0.1),
            // m68 (Lawrence: no bounce): critically damped springs, no overshoot.
            "K11": .spring(response: 0.12, damping: 1),
            "K12": .spring(response: 0.2, damping: 1),
            // The current close spring (PaneMotionVariant.standard.closeSpring, `.split`), for V6 on the current curve.
            "CUR": .spring(response: 0.23, damping: 0.95),
        ]

        /// The fraction of the travel done `t` seconds in (a spring may pass 1 and come back).
        public func progress(_ t: Double) -> Double {
            switch self {
            case let .bezier(x1, y1, x2, y2, seconds):
                guard seconds > 0, t < seconds else { return 1 }
                return Self.bezierY(max(0, t) / seconds, x1, y1, x2, y2)
            case let .spring(response, damping):
                let solved = SpringValue.solve(displacement: -1, velocity: 0, time: max(0, t),
                                               parameters: SpringParameters(response: response, dampingFraction: damping))
                return 1 + solved.displacement
            }
        }

        /// When a travel of `points` ends: a bezier at its time, a spring once it stays within 0.5 pt of rest (m63: "settle
        /// time to 0.5 px").
        public func endSeconds(travel points: Double) -> Double {
            switch self {
            case let .bezier(_, _, _, _, seconds): return seconds
            case .spring:
                guard points > 0.5 else { return 0 }
                var t = 2.0
                while t > 0, abs(1 - progress(t)) * points < 0.5 { t -= 0.001 }
                return min(2, t + 0.001)
            }
        }

        /// y of the cubic bezier (0,0) (x1,y1) (x2,y2) (1,1) at `x` (Newton, then bisection).
        static func bezierY(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
            func bx(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t }
            func by(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t }
            func dbx(_ t: Double) -> Double { let u = 1 - t; return 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2) }
            var t = x
            for _ in 0..<8 {
                let d = dbx(t)
                guard abs(d) > 1e-6 else { break }
                t = min(1, max(0, t - (bx(t) - x) / d))
            }
            if abs(bx(t) - x) > 1e-5 {
                var (lo, hi) = (0.0, 1.0)
                t = x
                for _ in 0..<40 {
                    if bx(t) < x { lo = t } else { hi = t }
                    t = (lo + hi) / 2
                }
            }
            return by(t)
        }
    }

    public var kind: Kind
    public var milliseconds: Double
    public var curve: Curve
    /// The CURVE SET curve this selection plays ("K2"), nil for the 150 ms default (``curve`` and ``milliseconds``).
    public var named: String?
    /// MOTION LAB (``MotionLab``): the shape the lab picked, with its time and slow motion; before ``named``.
    public var custom: Shape?
    /// The shape a motion of this selection takes: the named curve, else ``curve`` over ``milliseconds``.
    public var shape: Shape {
        if let custom { return custom }
        if let named, let shape = Shape.named[named] { return shape }
        switch curve {
        case .bezier: return .bezier(x1: 0.2, y1: 0, x2: 0, y2: 1, seconds: duration)
        case .spring: return .spring(response: duration / 6.6 * 2 * .pi, damping: 1)
        }
    }

    /// The current close (V0) and V2 (the same code path: the survivor's final grid goes at the spring's start and the
    /// surface is held at its final size, clipped by its growing frame) with a CURVE SET curve: the pane and divider
    /// frames move on that curve instead of the split spring. Nil with no curve named (the build's own close).
    public var frameCurve: Shape? {
        if let custom, kind == .v0 || kind == .v6 { return custom }
        if kind == .v6 { return named.flatMap { Shape.named[$0] } ?? Shape.named["CUR"] }
        guard let named, let shape = Shape.named[named] else { return nil }
        switch kind {
        case .v0, .v2, .v2b: return shape
        case .v1, .v3, .v4, .v5, .v6: return nil
        }
    }

    /// V6: the frames move on ``frameCurve`` (the current close's path, nothing snaps) and the closed pane's last picture
    /// fades out above them on the same progress.
    public var growsAndFades: Bool { kind == .v6 }

    /// Film diagnostics (``select(_:)`` answers them): how often each film grid path ran since the last read. Kept on the
    /// app's design settings (``DesignSettings/filmCounters``), not in a static.
    @MainActor public static func count(_ key: String) { DesignSettings.shared.filmCounters[key, default: 0] += 1 }

    public init(kind: Kind = .v0, milliseconds: Double = 150, curve: Curve = .bezier) {
        self.kind = kind
        self.milliseconds = milliseconds
        self.curve = curve
    }

    /// The selection the launch variables name (V0 at 150 ms on the bezier when they are not set).
    public init(environment: [String: String]) {
        self.init()
        if let raw = environment["CMUX_FILM_CLOSE_VARIANT"], let kind = Self.kind(raw) { self.kind = kind }
        if let raw = environment["CMUX_FILM_CLOSE_MS"], let ms = Double(raw), ms >= 0 { milliseconds = ms }
        if let raw = environment["CMUX_FILM_CLOSE_CURVE"] {
            if let curve = Curve(rawValue: raw.lowercased()) { self.curve = curve } else if Shape.named[raw.uppercased()] != nil { named = raw.uppercased() }
        }
    }

    /// `raw` as a kind, any letter case ("v2b", "V2B").
    public static func kind(_ raw: String) -> Kind? {
        Kind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }

    /// The selection a close plays, nil for the current close (V0, and V2 and V2b, which are not built yet).
    public var active: FilmCloseVariant? {
        switch kind {
        case .v0, .v2, .v2b, .v6: nil
        case .v1, .v3, .v4, .v5: self
        }
    }

    /// The closed pane's last picture stays on top for the motion (V3, V4, V5).
    public var keepsPicture: Bool { kind == .v3 || kind == .v4 || kind == .v5 }
    /// The picture slides out toward its far edge (V3, V5).
    public var slides: Bool { kind == .v3 || kind == .v5 }
    /// The picture fades out (V4, V5).
    public var fades: Bool { kind == .v4 || kind == .v5 }

    public var duration: TimeInterval { milliseconds / 1000 }

    /// The corner label a VIEW film shows for this selection ("V3 K6", "V0 150 ms").
    public var label: String { "\(kind.rawValue) \(named ?? "\(Int(milliseconds)) ms")" }

    /// True only while a film snap (V1, V3, V4, V5) draws the survivors' final sizes ahead in the close's turn
    /// (`ScreenContentView.holdsSnapForContent`): each terminal given a size then also sends the grid of that size to its
    /// PTY in this turn, in the presenter's pass before the commit (lead m60: "the grid is sent in the key turn, before the
    /// first commit"). The program redraws at its final grid while the old picture is held for one tick; the tick then
    /// shows the survivor at its final size with its final grid. Before, the grid went only when that size landed (key +
    /// 33-44 ms in the cv-b-1 films, build bb732e33), so the final grid showed 3-6 refreshes after the key.
    public var snapSendsGrid = false

    /// `debug.frames {"action": "close_variant V3 150 bezier"}` (any words in any order; none: only reads): sets the
    /// selection the next closes play and answers it. A film-only route on an existing probe, so the App gains no lines.
    @MainActor public static func select(_ command: String) -> [String: Any] {
        var film = DesignSettings.shared.filmClose
        film.custom = nil // the film kit's words, not a Motion Lab pick
        for word in command.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," }).dropFirst().map(String.init) {
            if let kind = kind(word) { film.kind = kind } else if let curve = Curve(rawValue: word.lowercased()) { (film.curve, film.named) = (curve, nil) }
            else if Shape.named[word.uppercased()] != nil { film.named = word.uppercased() } else if word.lowercased() == "nocurve" { film.named = nil }
            else if let ms = Double(word), ms >= 0 { film.milliseconds = ms } else { return ["error": "close_variant: unknown word \(word)"] }
        }
        DesignSettings.shared.filmClose = film
        let counters = DesignSettings.shared.filmCounters
        DesignSettings.shared.filmCounters = [:]
        return ["variant": film.kind.rawValue, "ms": film.milliseconds, "curve": film.curve.rawValue, "named": film.named ?? "",
                "plays": film.active?.kind.rawValue ?? "V0", "frame_curve": film.frameCurve != nil, "counters": counters]
    }

    /// `layer.keyPath` from `from` to `value` over this variant's duration on its curve, through the pane motion gate
    /// (`Motion.panes`). With its movement off (the master switch, the category, `ui.animationSpeed` off or
    /// Reduce Motion) the value applies at once. `completion` runs when it ends (at once with no animation).
    @MainActor public func animate(_ layer: CALayer, _ keyPath: String, from: Any, to value: Any,
                                   completion: @escaping @MainActor () -> Void) {
        guard Motion.panes.animatesMovement, duration > 0 || named != nil || custom != nil else {
            Motion.setModel(layer, keyPath, value)
            completion()
            return
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        FilmCloseCompletion(completion: completion).install()
        Motion.setModel(layer, keyPath, value)
        let animation: CABasicAnimation
        switch shape {
        case let .bezier(x1, y1, x2, y2, seconds):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            animation.duration = seconds
        case let .spring(response, damping):
            // SwiftUI response and damping fraction, mass 1: stiffness (2 pi / response)^2, damping 2 zeta omega.
            let spring = CASpringAnimation(keyPath: keyPath)
            let omega = 2 * Double.pi / max(response, 0.001)
            spring.mass = 1
            spring.stiffness = omega * omega
            spring.damping = 2 * damping * omega
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            animation = spring
        }
        animation.fromValue = from
        animation.toValue = value
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).film-close")
    }
}

/// The film close's CA completion on the main actor (a seam adapter: Core Animation calls the block on the main thread).
struct FilmCloseCompletion {
    let completion: @MainActor () -> Void

    func install() {
        let completion = self.completion
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: CATransaction.h: the completion block is called on the main thread
    }
}

/// A view that sends the PTY the grid of its final size in a film snap's turn (``FilmCloseVariant/snapSendsGrid``): the
/// terminal surface. DEBUG and bench builds only, branch close-variants/film-selector-nomerge, never merged.
@MainActor
public protocol FilmSnapGridSending: NSView {
    /// The enclosing pane's content area will be `sizeChange` larger (negative: smaller) at the snap's tick.
    func filmSendSnapGrid(sizeChange: CGSize)
}

public extension NSView {
    /// Every ``FilmSnapGridSending`` view in this subtree (this view included) sends its final grid now.
    @MainActor func filmSendSnapGrids(sizeChange: CGSize) {
        if let sender = self as? FilmSnapGridSending { sender.filmSendSnapGrid(sizeChange: sizeChange) }
        for subview in subviews { subview.filmSendSnapGrids(sizeChange: sizeChange) }
    }
}

#endif
