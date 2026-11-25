import CoreGraphics
import Foundation

/// T-SCROLL-12: a vertical drag over a full-screen app (the alternate
/// screen) scrolls the app, like a Mac trackpad in Ghostty, and never the
/// page. The drag is an ordinary UIScrollView scroll (Leo, 2026-11-25: "for
/// scrolling on iphone ... we can just treat the scroll like any pedestrian
/// scroll"): each change of the scroll view's offset, the finger's and then
/// UIKit's deceleration, is one precise wheel delta in points, 1:1, in the
/// natural direction (a finger moving down lowers the offset and scrolls
/// toward older content, a wheel up); the deceleration's are momentum. The
/// surface scales them to pixels and Ghostty's own scroll path decides what
/// the app gets: SGR wheel reports (buttons 64/65) at the finger when it
/// asked for the mouse (DECSET 1000/1002/1003 + 1006), cursor up/down on the
/// alternate screen with alternate scroll (DECSET 1007, Ghostty's default),
/// and nothing otherwise.
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

    private var lastOffset: CGFloat = 0
    private var momentumBegan = false

    public init() {}

    /// The scroll view's offset is `offset` and no scroll is under way (a
    /// new drag, or the offset moved back to the middle of its range).
    public mutating func reset(offset: CGFloat) {
        lastOffset = offset
    }

    /// The scroll view's offset moved to `offset`, under the finger when
    /// `tracking`, else in its deceleration: the wheel for the movement
    /// since the last report (nil when it did not move).
    public mutating func scrolled(to offset: CGFloat, tracking: Bool) -> Wheel? {
        let delta = lastOffset - offset
        lastOffset = offset
        guard delta != 0 else { return nil }
        guard !tracking else { return Wheel(dy: delta, momentum: .none) }
        defer { momentumBegan = true }
        return Wheel(dy: delta, momentum: momentumBegan ? .changed : .began)
    }

    /// The scroll ended (the finger lifted with no fling, the fling stopped
    /// or was stopped): the end of the momentum phase, once, if one began.
    public mutating func ended() -> Wheel? {
        guard momentumBegan else { return nil }
        momentumBegan = false
        return Wheel(dy: 0, momentum: .ended)
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
