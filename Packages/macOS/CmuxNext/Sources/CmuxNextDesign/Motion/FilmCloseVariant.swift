#if DEBUG || CMUX_BENCH_HOOKS
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
    }

    public enum Curve: String, Sendable {
        /// cubic-bezier(0.2, 0, 0, 1), ease-out.
        case bezier
        /// A critically damped spring (no overshoot) that settles in the duration.
        case spring
    }

    public var kind: Kind
    public var milliseconds: Double
    public var curve: Curve

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
        if let raw = environment["CMUX_FILM_CLOSE_CURVE"], let curve = Curve(rawValue: raw.lowercased()) { self.curve = curve }
    }

    /// `raw` as a kind, any letter case ("v2b", "V2B").
    public static func kind(_ raw: String) -> Kind? {
        Kind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }

    /// The selection a close plays, nil for the current close (V0, and V2 and V2b, which are not built yet).
    public var active: FilmCloseVariant? {
        switch kind {
        case .v0, .v2, .v2b: nil
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

    /// `debug.frames {"action": "close_variant V3 150 bezier"}` (any words in any order; none: only reads): sets the
    /// selection the next closes play and answers it. A film-only route on an existing probe, so the App gains no lines.
    @MainActor public static func select(_ command: String) -> [String: Any] {
        var film = DesignSettings.shared.filmClose
        for word in command.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," }).dropFirst().map(String.init) {
            if let kind = kind(word) { film.kind = kind } else if let curve = Curve(rawValue: word.lowercased()) { film.curve = curve }
            else if let ms = Double(word), ms >= 0 { film.milliseconds = ms } else { return ["error": "close_variant: unknown word \(word)"] }
        }
        DesignSettings.shared.filmClose = film
        return ["variant": film.kind.rawValue, "ms": film.milliseconds, "curve": film.curve.rawValue, "plays": film.active?.kind.rawValue ?? "V0"]
    }

    /// `layer.keyPath` from `from` to `value` over this variant's duration on its curve, through the pane motion gate
    /// (`Motion.panes`). With its movement off (the master switch, the category, `ui.animationSpeed` off or
    /// Reduce Motion) the value applies at once. `completion` runs when it ends (at once with no animation).
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
        switch curve {
        case .bezier:
            animation = CABasicAnimation(keyPath: keyPath)
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        case .spring:
            // Critically damped: (1 + wt) e^(-wt) is 1% at wt = 6.6, so it is at rest when the duration ends.
            let spring = CASpringAnimation(keyPath: keyPath)
            let omega = 6.6 / duration
            spring.mass = 1
            spring.stiffness = omega * omega
            spring.damping = 2 * omega
            spring.initialVelocity = 0
            animation = spring
        }
        animation.duration = duration
        animation.fromValue = from
        animation.toValue = value
        Motion.add(animation, to: layer, keyPath: keyPath, trace: "layer.\(keyPath).film-close")
    }
}

#endif
