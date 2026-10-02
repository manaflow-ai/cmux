import Foundation
import QuartzCore

/// The curve of one additive motion component. The send and flight springs
/// are fitted to the Messages reference recording
/// (MessagesLab `shared/motion/springs.json`); they are module-specific
/// measurements, not chrome tokens, so they live here with reviewed
/// `motion-allow` exceptions. `Motion.animatesMovement` (Reduce Motion,
/// `ui.animationSpeed = off`) decides whether they run at all
/// (``TranscriptMotionPolicy``).
nonisolated enum TranscriptTiming: Equatable, Sendable {
    /// CASpringAnimation: mass, stiffness, damping, initial velocity (distance units per second).
    case spring(mass: Double, stiffness: Double, damping: Double, velocity: Double)
    /// CABasicAnimation over a duration with a cubic Bezier timing function.
    case curve(duration: Double, x1: Double, y1: Double, x2: Double, y2: Double)
    /// Holds the delta for the duration, then 0.
    case hold(duration: Double)

    // motion-allow: fitted to the reference recording (springs.json send_scroll)
    static let sendScroll = TranscriptTiming.spring(mass: 1, stiffness: 440.33, damping: 42.023, velocity: 0)
    // motion-allow: fitted flight edges (springs.json flight_screen_edges T, B, R, L two springs)
    static let flightTop = TranscriptTiming.spring(mass: 1, stiffness: 117.3, damping: 16.647, velocity: -2.757)
    // motion-allow: fitted flight edge B
    static let flightBottom = TranscriptTiming.spring(mass: 1, stiffness: 161.39, damping: 16.372, velocity: 2.342)
    // motion-allow: fitted flight edge R
    static let flightRight = TranscriptTiming.spring(mass: 1, stiffness: 114.54, damping: 15.478, velocity: 5.059)
    // motion-allow: fitted flight edge L, first spring
    static let flightLeftA = TranscriptTiming.spring(mass: 1, stiffness: 218.446, damping: 21.677, velocity: 0.019)
    // motion-allow: fitted flight edge L, overshoot return
    static let flightLeftB = TranscriptTiming.spring(mass: 1, stiffness: 426.154, damping: 29.539, velocity: 0)
    /// Row insert scrolls (received, typing): the reference fits this Bezier better than a spring.
    // motion-allow: fitted Bezier (springs.json reply_scroll bezier)
    static let received = TranscriptTiming.curve(duration: 0.257, x1: 0.226, y1: 0, x2: 0.667, y2: 1)
    // motion-allow: fitted Bezier (springs.json typing_scroll bezier)
    static let grow = TranscriptTiming.curve(duration: 0.26, x1: 0.226, y1: 0, x2: 0.667, y2: 1)
    // motion-allow: fitted Bezier (springs.json read_collapse_scroll bezier)
    static let receiptChange = TranscriptTiming.curve(duration: 0.248, x1: 0.226, y1: 0, x2: 0.667, y2: 1)
    static func fadeIn(_ seconds: Double) -> TranscriptTiming {
        .curve(duration: seconds, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    }
    /// The fill and text fade of the flying bubble.
    // motion-allow: measured fade of the flying bubble (MessagesLab Scene flight fill/text)
    static let flightFade = TranscriptTiming.curve(duration: 0.2, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    /// How long the flying bubble exists; the row shows when it ends.
    static let flightDuration = 0.6

    /// Progress from 0 (at x <= 0) toward 1.
    func progress(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        switch self {
        case .spring(let m, let k, let c, let v0): return Self.springProgress(x, m: m, k: k, c: c, v0: v0)
        case .curve(let d, let x1, let y1, let x2, let y2): return Self.bezier(x / d, x1, y1, x2, y2)
        case .hold(let d): return x < d ? 0 : 1
        }
    }

    /// The closed-form damped oscillator that CASpringAnimation renders.
    static func springProgress(_ x: Double, m: Double, k: Double, c: Double, v0: Double) -> Double {
        let w0 = (k / m).squareRoot(), z = c / (2 * (k * m).squareRoot())
        if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            let b = (z * w0 - v0) / wd
            return 1 - exp(-z * w0 * x) * (cos(wd * x) + b * sin(wd * x))
        }
        if abs(z - 1) < 1e-6 { return 1 - exp(-w0 * x) * (1 + (w0 - v0) * x) }
        let s = (z * z - 1).squareRoot()
        let r1 = -w0 * (z - s), r2 = -w0 * (z + s)
        let a = (v0 + r2) / (r1 - r2)
        return 1 + a * exp(r1 * x) + (-1 - a) * exp(r2 * x)
    }

    /// Cubic Bezier easing y(x) with control points (x1, y1), (x2, y2).
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var s = x
        for _ in 0..<12 {
            let bx = 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s
            let dx = 3 * (1 - s) * (1 - s) * x1 + 6 * (1 - s) * s * (x2 - x1) + 3 * s * s * (1 - x2)
            s = min(1, max(0, s - (bx - x) / max(dx, 1e-6)))
        }
        return 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s
    }

    /// Seconds until the motion is within 0.1 % of its distance.
    var settle: Double {
        switch self {
        case .spring(let m, let k, let c, _):
            let w0 = (k / m).squareRoot(), z = c / (2 * (k * m).squareRoot())
            return min(3, -log(0.001) / (min(z, 1) * w0) + 0.05)
        case .curve(let d, _, _, _, _), .hold(let d): return d
        }
    }

    /// The additive Core Animation animation for a component that starts
    /// `delta` (layer units) away from the model value and ends at it.
    @MainActor
    func animation(keyPath: String, delta: CGFloat) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch self {
        case .spring(let m, let k, let c, let v0):
            // motion-allow: render-server spring with fitted constants (see the type comment)
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = m
            spring.stiffness = k
            spring.damping = c
            spring.initialVelocity = v0
            spring.duration = settle
            spring.fromValue = delta
            spring.toValue = 0
            animation = spring
        case .curve(let d, let x1, let y1, let x2, let y2):
            // motion-allow: render-server curve with fitted control points
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = d
            // motion-allow: fitted Bezier control points
            animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            animation.fromValue = delta
            animation.toValue = 0
        case .hold(let d):
            // motion-allow: holds a value for the flight's lifetime
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = d
            animation.fromValue = delta
            animation.toValue = delta
        }
        animation.isAdditive = true
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        return animation
    }
}
