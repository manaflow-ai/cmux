#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation
public import QuartzCore

/// ZOOM VARIANTS film selector (cmux-ad m64, task zoom-variants): which Toggle Pane Zoom (Cmd-Shift-Enter) motion a film
/// shows, so Lawrence can compare them side by side and pick one. DEBUG and bench builds only; it never ships. Branch
/// zoom-variants/film-selector-nomerge only: never merged, never a PR. After the pick, the winner lands with no selector.
///
/// Set by the film harness: the launch variables `CMUX_FILM_ZOOM_VARIANT` (V0, Z1, Z2, Z3) and `CMUX_FILM_ZOOM_CURVE`
/// (K1 ... K10, default K2), or at run time `debug.frames {"action": "zoom_variant Z2 K6"}` (``select(_:)``).
///
/// Z1, Z2 and Z3 show the zoom in the key's turn (a store intent, not the daemon's echo), snap the layout to its final
/// frames (one resize per terminal), send each resized terminal's final grid in that turn, and keep the old picture for
/// one frame tick, until the terminals have their frames at the new sizes (`ScreenContentView+SnapFrame`).
public struct FilmZoomVariant: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The current zoom: the daemon's echo, then the zoomed pane springs over the others (reference).
        case v0 = "V0"
        /// Instant: the final layout and the final grids in the key's turn, shown at the next tick.
        case z1 = "Z1"
        /// Grow: the zoomed pane at its final size and grid at once, shown through a frame that grows from its old frame
        /// to the full screen (out: its old full picture shrinks to its place, over the final layout).
        case z2 = "Z2"
        /// Cover-out: the zoomed pane at its final size at once, under the other panes' last pictures, which slide out
        /// and fade (out: the other panes slide in and fade in over the zoomed pane's old full picture).
        case z3 = "Z3"
        /// Grow and fade (m66, Lawrence: "when i do cmd shift enter i want to see the rest of it fade, in the same easing
        /// function"): the zoomed pane's frame grows from its place to the full screen (its content at the final grid,
        /// its top-left on the frame's) while every other pane fades out in place, on one progress value of the curve
        /// (opacity clamped to 0 ... 1 on a spring's overshoot). Out: the exact reverse.
        case z4 = "Z4"
    }

    /// The m63 curve set (tasks/close-variants.md): bezier curves with a duration, springs with a damping ratio and a
    /// response.
    public enum Curve: String, Sendable, CaseIterable {
        /// The current zoom spring (`MotionSpring.zoom`'s code default: response 0.2 s, critically damped).
        case cur = "CUR"
        case k1 = "K1", k2 = "K2", k3 = "K3", k4 = "K4", k5 = "K5", k6 = "K6", k7 = "K7", k8 = "K8", k9 = "K9", k10 = "K10"
        /// m68 ("i dont want a bounce animation"): critically damped, 0.12 s and 0.2 s response.
        case k11 = "K11", k12 = "K12"

        /// Bezier control points and seconds; nil for a spring.
        var bezier: (points: (Float, Float, Float, Float), seconds: Double)? {
            switch self {
            case .k1: ((0.2, 0, 0, 1), 0.08)
            case .k2: ((0.2, 0, 0, 1), 0.10)
            case .k3: ((0.2, 0, 0, 1), 0.12)
            case .k4: ((0.22, 1, 0.36, 1), 0.10)
            case .k5: ((0.65, 0, 0.35, 1), 0.12)
            case .k10: ((0, 0, 1, 1), 0.10)
            case .cur, .k6, .k7, .k8, .k9, .k11, .k12: nil
            }
        }

        /// Damping ratio and response (s); nil for a bezier curve.
        var spring: (damping: Double, response: Double)? {
            switch self {
            case .cur: (1.0, 0.2)
            case .k6: (1.0, 0.15)
            case .k7: (0.9, 0.18)
            case .k8: (0.8, 0.20)
            case .k9: (0.7, 0.25)
            case .k11: (1.0, 0.12)
            case .k12: (1.0, 0.20)
            default: nil
            }
        }
    }

    public var kind: Kind
    public var curve: Curve
    /// MOTION LAB (``MotionLab``): the curve the lab picked, with its time and slow motion; before ``curve``.
    public var custom: FilmProgressDriver.Curve?

    /// The bezier this selection plays (control points and seconds); nil for a spring.
    var bezier: (points: (Float, Float, Float, Float), seconds: Double)? {
        switch custom {
        case let .bezier(x1, y1, x2, y2, seconds)?: ((x1, y1, x2, y2), seconds)
        case .spring?: nil
        case nil: curve.bezier
        }
    }

    /// The spring this selection plays (damping ratio and response); nil for a bezier.
    var spring: (damping: Double, response: Double)? {
        switch custom {
        case let .spring(damping, response)?: (damping, response)
        case .bezier?: nil
        case nil: curve.spring
        }
    }

    public init(kind: Kind = .v0, curve: Curve = .k2) {
        self.kind = kind
        self.curve = curve
    }

    /// The selection the launch variables name (V0 on K2 when they are not set).
    public init(environment: [String: String]) {
        self.init()
        if let raw = environment["CMUX_FILM_ZOOM_VARIANT"], let kind = Self.kind(raw) { self.kind = kind }
        if let raw = environment["CMUX_FILM_ZOOM_CURVE"], let curve = Self.curve(raw) { self.curve = curve }
    }

    public static func kind(_ raw: String) -> Kind? {
        raw.lowercased() == "z0" ? .v0 : Kind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() } // Z0 = V0 (m66)
    }
    public static func curve(_ raw: String) -> Curve? { Curve.allCases.first { $0.rawValue.lowercased() == raw.lowercased() } }

    /// The selection a zoom plays, nil for the current zoom (V0).
    public var active: FilmZoomVariant? { kind == .v0 ? nil : self }

    /// `debug.frames {"action": "zoom_variant Z2 K6"}` (any words in any order; none: only reads): sets the selection
    /// the next zooms play and answers it, with the spring's settle time to 0.5 pt over `travel` points (`travel=900`).
    @MainActor public static func select(_ command: String) -> [String: Any] {
        var film = DesignSettings.shared.filmZoom
        film.custom = nil // the film kit's words, not a Motion Lab pick
        var travel = 900.0
        for word in command.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," }).dropFirst().map(String.init) {
            if let kind = kind(word) { film.kind = kind } else if let curve = curve(word) { film.curve = curve }
            else if word.hasPrefix("travel="), let value = Double(word.dropFirst(7)), value > 0 { travel = value }
            else { return ["error": "zoom_variant: unknown word \(word)"] }
        }
        DesignSettings.shared.filmZoom = film
        var answer: [String: Any] = ["variant": film.kind.rawValue, "curve": film.curve.rawValue, "plays": film.active?.kind.rawValue ?? "V0",
                                     "duration_ms": film.duration * 1000]
        if film.spring != nil {
            answer["settle_ms"] = film.settleTime(travel: travel, within: 0.5) * 1000
            answer["overshoot_pt"] = film.driver.overshoot * travel // m68: must be < 0.5
        }
        return answer
    }

    /// The curve's length: a bezier's duration, a spring's settle time to 0.5 pt over 900 pt.
    public var duration: TimeInterval {
        if let bezier = self.bezier { return bezier.seconds }
        return settleTime(travel: 900, within: 0.5)
    }

    /// A spring's time until it stays within `within` of its target, from rest `travel` away (sampled at 1 ms).
    public func settleTime(travel: Double, within: Double) -> TimeInterval {
        guard let spring = self.spring else { return bezier?.seconds ?? 0 }
        let (stiffness, damping) = Self.coefficients(spring)
        var x = travel, v = 0.0, t = 0.0, last = 0.0
        let dt = 0.0005
        while t < 2 {
            let a = -stiffness * x - damping * v
            v += a * dt
            x += v * dt
            t += dt
            if abs(x) > within { last = t }
        }
        return last
    }

    /// Mass 1: stiffness (2 pi / response)^2, damping 4 pi ratio / response (SwiftUI's spring(response:dampingFraction:)).
    static func coefficients(_ spring: (damping: Double, response: Double)) -> (stiffness: Double, damping: Double) {
        let omega = 2 * Double.pi / spring.response
        return (omega * omega, 2 * spring.damping * omega)
    }

    /// `layer.keyPath` from `from` to `value` on this variant's curve, through the pane motion gate (`Motion.panes`). With
    /// its movement off (the master switch, the category, `ui.animationSpeed` off or Reduce Motion) the value applies at
    /// once. `completion` runs when it ends (at once with no animation).
    @MainActor public func animate(_ layer: CALayer, _ keyPath: String, from: Any, to value: Any,
                                   completion: @escaping @MainActor () -> Void) {
        guard Motion.panes.animatesMovement, duration > 0 else {
            Motion.setModel(layer, keyPath, value)
            completion()
            return
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } // main-proof: CATransaction.h: the completion block is called on the main thread
        Motion.setModel(layer, keyPath, value)
        let animation: CABasicAnimation
        if let bezier = self.bezier {
            animation = CABasicAnimation(keyPath: keyPath)
            let p = bezier.points
            animation.timingFunction = CAMediaTimingFunction(controlPoints: p.0, p.1, p.2, p.3)
            animation.duration = bezier.seconds
        } else if let spring = self.spring {
            let (stiffness, damping) = Self.coefficients(spring)
            let motion = CASpringAnimation(keyPath: keyPath)
            motion.mass = 1
            motion.stiffness = stiffness
            motion.damping = damping
            motion.initialVelocity = 0
            motion.duration = duration
            animation = motion
        } else {
            return
        }
        animation.fromValue = from
        animation.toValue = value
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).film-zoom")
    }

    /// The one-value driver on this variant's curve (``FilmProgressDriver``).
    public var driver: FilmProgressDriver {
        if let spring = self.spring { return FilmProgressDriver(damping: spring.damping, response: spring.response) }
        let bezier = self.bezier ?? ((0, 0, 1, 1), 0.1)
        return FilmProgressDriver(points: bezier.points, seconds: bezier.seconds)
    }

    /// `layer.keyPath` driven by ONE progress value of this variant's curve (``FilmProgressDriver/drive(_:_:_:completion:)``).
    @MainActor public func drive(_ layer: CALayer, _ keyPath: String, _ value: (Double) -> Any,
                                 completion: @escaping @MainActor () -> Void) {
        driver.drive(layer, keyPath, value, completion: completion)
    }
}

#endif
