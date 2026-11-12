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
///
/// Like a Mac trackpad's accelerated deltas, a fast finger moves the wheel
/// further than the finger (``gain(speed:)``): 1:1 up to ``preciseSpeed``,
/// so a slow drag still scrolls line by line, rising to ``maximumGain`` at
/// ``fullSpeed``. Without it a flick through a long Claude Code transcript
/// moved about a quarter of what the same flick moves on the Mac.
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

    /// Finger speeds (points per second) up to this scroll 1:1.
    public static let preciseSpeed: CGFloat = 300
    /// From this speed on the wheel moves ``maximumGain`` times the finger.
    public static let fullSpeed: CGFloat = 3000
    public static let maximumGain: CGFloat = 3

    private var lastTranslation: CGFloat = 0

    public init() {}

    /// How far the wheel moves per point of finger at `speed` (points per
    /// second, either sign): 1 up to ``preciseSpeed``, then linear up to
    /// ``maximumGain`` at ``fullSpeed``.
    public static func gain(speed: CGFloat) -> CGFloat {
        let speed = abs(speed)
        guard speed > preciseSpeed else { return 1 }
        let fraction = min(1, (speed - preciseSpeed) / (fullSpeed - preciseSpeed))
        return 1 + (maximumGain - 1) * fraction
    }

    /// A drag began: its translation counts from here.
    public mutating func began() {
        lastTranslation = 0
    }

    /// The drag's running vertical translation and the finger's vertical
    /// speed: the wheel for the movement since the last report, scaled by
    /// ``gain(speed:)`` (nil when the finger did not move vertically).
    public mutating func moved(translationY: CGFloat, velocityY: CGFloat = 0) -> Wheel? {
        let delta = translationY - lastTranslation
        lastTranslation = translationY
        guard delta != 0 else { return nil }
        return Wheel(dy: delta * Self.gain(speed: velocityY), momentum: .none)
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

/// The fling after a TUI drag: wheel deltas from the release speed times the
/// drag's gain (``TerminalTUIScroll/gain(speed:)``), decaying like the
/// browser stream's momentum (0.95 per 1/60 s), as macOS momentum events
/// (began, changed..., ended).
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
        velocity = velocityY * TerminalTUIScroll.gain(speed: velocityY)
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

/// Whether a tap over a full-screen app is a click (Leo, 2026-11-12: "this
/// terminal projection nigh unusable due to me scroll and thumb land on
/// subagent depiction"). A tap is the app's click when it asked for the
/// mouse, so a thumb flicking through a Claude Code transcript clicked
/// whatever row it landed on (a background agent, which opened its view).
/// A tap clicks only when it is a deliberate tap: it lands when the app is
/// not scrolling (``quietAfterScroll`` after the last wheel, as a tap on a
/// moving UIScrollView only stops it), stays within ``maximumMovement`` and
/// lifts within ``maximumHold``. A touch that lands while the app scrolls
/// does nothing else either (``Verdict/ignore``); a slow or moving tap
/// still focuses the terminal, without the click.
public struct TerminalTUITapClick: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The app's click, and the terminal takes the keyboard.
        case click
        /// Only the terminal takes the keyboard.
        case focusOnly
        /// Nothing: the touch was part of scrolling.
        case ignore
    }

    /// A touch that lands this soon after a wheel (seconds) is still scrolling.
    public static let quietAfterScroll: TimeInterval = 0.5
    /// A tap held longer than this (seconds) is a resting thumb, not a click
    /// (under the 0.5 s long press that selects).
    public static let maximumHold: TimeInterval = 0.45
    /// A tap that moved farther than this (points) is a short flick.
    public static let maximumMovement: CGFloat = 6

    private var lastWheel: TimeInterval?

    public init() {}

    /// A wheel event went to the app at `time` (seconds, the touch clock).
    public mutating func scrolled(at time: TimeInterval) {
        lastWheel = time
    }

    /// The tap whose finger landed at `downAt`, lifted at `upAt` and moved
    /// `moved` points between.
    public func verdict(downAt: TimeInterval, upAt: TimeInterval, moved: CGFloat) -> Verdict {
        if let lastWheel, downAt - lastWheel < Self.quietAfterScroll { return .ignore }
        guard upAt - downAt <= Self.maximumHold, moved <= Self.maximumMovement else { return .focusOnly }
        return .click
    }
}
