import CoreGraphics
import Foundation

/// T-SCROLL-12: a vertical drag over a full-screen app (the alternate
/// screen) scrolls the app, like a Mac trackpad in Ghostty, and never the
/// page. The phone turns the finger into precise wheel deltas in points, in
/// the natural direction (a finger moving down scrolls toward older content,
/// a wheel up), and a release with speed into momentum deltas that decay.
/// The surface scales them to pixels and Ghostty's own scroll path decides
/// what the app gets: SGR wheel reports (buttons 64/65) at the finger when
/// it asked for the mouse (DECSET 1000/1002/1003 + 1006), cursor up/down on
/// the alternate screen with alternate scroll (DECSET 1007, Ghostty's
/// default), and nothing otherwise.
public struct TerminalTUIScroll: Equatable, Sendable {
    /// Ghostty's momentum phases (`ghostty_input_mouse_momentum_e`).
    public enum Momentum: Int32, Sendable {
        case none = 0
        case began = 1
        case changed = 3
        case ended = 4
    }

    /// One wheel event: `dy` in points, positive scrolls up (older content).
    public struct Wheel: Equatable, Sendable {
        public var dy: CGFloat
        public var momentum: Momentum

        public init(dy: CGFloat, momentum: Momentum) {
            self.dy = dy
            self.momentum = momentum
        }
    }

    private var lastTranslation: CGFloat = 0

    public init() {}

    /// A drag began: its translation counts from here.
    public mutating func began() {
        lastTranslation = 0
    }

    /// The drag's running vertical translation: the wheel for the movement
    /// since the last report (nil when the finger did not move vertically).
    public mutating func moved(translationY: CGFloat) -> Wheel? {
        let delta = translationY - lastTranslation
        lastTranslation = translationY
        guard delta != 0 else { return nil }
        return Wheel(dy: delta, momentum: .none)
    }

    /// Ghostty's packed scroll mods (src/input/mouse.zig ScrollMods): bit 0
    /// precision (the delta is in pixels, like a trackpad), bits 1-3 the
    /// momentum phase.
    public static func mods(_ momentum: Momentum) -> Int32 {
        1 | (momentum.rawValue << 1)
    }

    /// A drag scrolls the app only when it starts mostly vertical (`motion`:
    /// its translation so far, or its velocity).
    public static func takesDrag(motion: CGPoint) -> Bool {
        let vertical = abs(motion.y), horizontal = abs(motion.x)
        return vertical > 0 && vertical > horizontal
    }
}

/// The fling after a TUI drag: wheel deltas from the release speed, decaying
/// like the browser stream's momentum (0.95 per 1/60 s), as macOS momentum
/// events (began, changed..., ended).
public struct TerminalTUIMomentum: Equatable, Sendable {
    /// Releases slower than this (points per second) stop where they are.
    public static let minimumVelocity: CGFloat = 200
    /// The fling ends once it is this slow.
    public static let stopVelocity: CGFloat = 20

    private var velocity: CGFloat
    private var began = false
    public private(set) var isFinished = false

    public init?(velocityY: CGFloat) {
        guard abs(velocityY) >= Self.minimumVelocity else { return nil }
        velocity = velocityY
    }

    /// One display frame of `dt` seconds: its wheel, the end once the fling
    /// is slow enough, then nil.
    public mutating func step(dt: CFTimeInterval) -> TerminalTUIScroll.Wheel? {
        guard !isFinished else { return nil }
        let dt = max(0, min(0.05, dt))
        velocity *= CGFloat(pow(0.95, dt * 60))
        if abs(velocity) < Self.stopVelocity {
            isFinished = true
            return began ? TerminalTUIScroll.Wheel(dy: 0, momentum: .ended) : nil
        }
        defer { began = true }
        return TerminalTUIScroll.Wheel(dy: velocity * CGFloat(dt), momentum: began ? .changed : .began)
    }

    /// A touch or leaving the app stops the fling: its end, once.
    public mutating func stop() -> TerminalTUIScroll.Wheel? {
        guard !isFinished else { return nil }
        isFinished = true
        return began ? TerminalTUIScroll.Wheel(dy: 0, momentum: .ended) : nil
    }
}
