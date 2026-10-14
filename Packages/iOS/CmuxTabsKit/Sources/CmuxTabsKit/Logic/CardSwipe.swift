import CoreGraphics

/// Swipe a grid card left to close it, as Safari does. Device reference:
/// iPhone 17 Pro Max Safari (`swipe-close-device.mp4`, real frame times,
/// the cmux-next iOS app's validation/browser.md round 16); thresholds from simulator Safari trials
/// (round 14):
///
/// - Horizontal drags only (a mostly vertical drag scrolls the grid). The card
///   lifts (scale 1.09) as soon as it is dragged. Left follows the finger 1:1;
///   right is rubber-banded (at most ≈ 58 pt seen on device) and always
///   springs back.
/// - No fade while dragging.
/// - Release closes when the card is at least 72% of its width to the left,
///   or when the finger leaves leftward faster than 225 pt/s; otherwise the
///   card springs back to its slot (0.66 / 0.86) and settles to scale 1
///   (0.57 / 0.94).
/// - Closing: the card keeps going left at the finger's speed (≥ 1000 pt/s),
///   lifted and opaque, then the grid reflows once the host confirmed (a
///   refused close brings the card back). When one tab is left, Safari opens
///   it.
struct CardSwipe: Equatable, Sendable {
    static let commitFraction: CGFloat = 0.72
    static let flingVelocity: CGFloat = 225
    /// Rightward rubber band: `d * (1 - 1 / (x * c / d + 1))`.
    static let rubberDimension: CGFloat = 120
    static let rubberConstant: CGFloat = 0.55
    /// Spring back to the slot (device: centre x fit 0.66 / 0.86, rms 0.6 pt).
    static let snapBack = ZoomSpring(response: 0.66, damping: 0.86)
    /// The card lifts while it is dragged (device: 1.0 -> 1.09 within ~60 ms
    /// of the drag starting, about its centre) and settles back on release
    /// (scale fit 0.57 / 0.94).
    static let liftScale: CGFloat = 1.09
    static let lift = ZoomSpring(response: 0.08, damping: 1)
    static let settle = ZoomSpring(response: 0.57, damping: 0.94)
    /// A closing card keeps going left at the finger's speed (device ≈ 1000
    /// pt/s, still lifted and opaque) until it is off screen.
    static let flyOffMinSpeed: CGFloat = 1000
    /// Fly-off time for `distance` points at the release speed.
    static func flyOffDuration(distance: CGFloat, velocity: CGFloat) -> Double {
        Double(abs(distance) / max(abs(velocity), flyOffMinSpeed))
    }
    /// Reduce Motion: no movement after release, a crossfade instead.
    static let reduceMotionFade = 0.18

    /// The card's offset for a finger translation.
    static func offset(translation dx: CGFloat) -> CGFloat {
        guard dx > 0 else { return dx }
        let d = rubberDimension
        return d * (1 - 1 / (dx * rubberConstant / d + 1))
    }

    /// Close on release? `offset` and `velocity` in points (/s), negative left.
    static func commits(offset: CGFloat, velocity: CGFloat, cardWidth: CGFloat) -> Bool {
        guard offset < 0, velocity < flingVelocity else { return false }
        return offset <= -commitFraction * cardWidth || velocity <= -flingVelocity
    }

    /// Where the fly-off ends: past the screen's leading edge.
    static func flyOffOffset(cardMinX: CGFloat, cardWidth: CGFloat) -> CGFloat {
        -(cardMinX + cardWidth + 24)
    }
}
