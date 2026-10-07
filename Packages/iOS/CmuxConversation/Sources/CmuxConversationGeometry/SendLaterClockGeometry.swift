import CoreGraphics
import Foundation

/// The Send Later clock, from ChatKit's `clock-sendlater.ca` (shared by iOS
/// and macOS Messages): a 15 pt circle (#20A6FE) with an hour and a minute
/// hand cut out of it. The package has no keyframes; ChatKit turns the hands
/// in code, so they point at the scheduled time here and sweep to a new time
/// when it changes. Coordinates are top-left origin.
public enum SendLaterClockGeometry {
    /// Document size of the reference layer tree.
    public static let size: CGFloat = 15
    /// `clock bg` fill, sRGB.
    public static let fill: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.1266, 0.65, 0.9949)

    public struct Hand: Sendable {
        public var width: CGFloat
        /// Length from the pivot to the tip.
        public var length: CGFloat
        /// How far the rounded tail pokes past the pivot.
        public var overshoot: CGFloat
    }

    /// `minute` sublayer: 1.5 x 6 at y -0.75 from the pivot, radius 0.75.
    public static let minuteHand = Hand(width: 1.5, length: 5.25, overshoot: 0.75)
    /// `hour` sublayer: 1.5 x 5 at y -0.674 from the pivot, radius 0.75.
    public static let hourHand = Hand(width: 1.5, length: 4.33, overshoot: 0.67)

    /// Clockwise angles from 12 o'clock, in radians.
    public static func angles(for date: Date, calendar: Calendar = .current) -> (hour: CGFloat, minute: CGFloat) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = CGFloat(parts.minute ?? 0)
        let hour = CGFloat((parts.hour ?? 0) % 12) + minute / 60
        return (hour / 12 * 2 * .pi, minute / 60 * 2 * .pi)
    }

    /// The minute hand's angle for `to`, unwound so it sweeps forward from
    /// `from` by the real minutes between the two times (at most two turns,
    /// as a long jump would only blur).
    public static func sweep(from: Date, to: Date, calendar: Calendar = .current) -> (hour: CGFloat, minute: CGFloat) {
        let start = angles(for: from, calendar: calendar)
        let minutes = to.timeIntervalSince(from) / 60
        let turns = min(2, max(-2, minutes / 60))
        let end = angles(for: to, calendar: calendar)
        var minute = end.minute
        // Pick the representation of the end angle closest to start + turns.
        let target = start.minute + CGFloat(turns) * 2 * .pi
        while minute - target > .pi { minute -= 2 * .pi }
        while target - minute > .pi { minute += 2 * .pi }
        var hour = end.hour
        while hour - start.hour > .pi { hour -= 2 * .pi }
        while start.hour - hour > .pi { hour += 2 * .pi }
        return (hour, minute)
    }

    /// A hand at rest (pointing to 12) as a rounded rect around a pivot at the
    /// origin, scaled for a clock of `diameter`.
    public static func handRect(_ hand: Hand, diameter: CGFloat) -> CGRect {
        let scale = diameter / size
        return CGRect(
            x: -hand.width / 2 * scale,
            y: -hand.length * scale,
            width: hand.width * scale,
            height: (hand.length + hand.overshoot) * scale
        )
    }

    /// The whole clock as one path (circle minus both hands), for static
    /// icons. Animated clocks draw the hands as layers instead.
    public static func path(diameter: CGFloat, date: Date, calendar: Calendar = .current, origin: CGPoint = .zero) -> CGPath {
        let center = CGPoint(x: origin.x + diameter / 2, y: origin.y + diameter / 2)
        let circle = CGPath(ellipseIn: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)), transform: nil)
        let a = angles(for: date, calendar: calendar)
        let hands = [(minuteHand, a.minute), (hourHand, a.hour)].map { hand, angle -> CGPath in
            let rect = handRect(hand, diameter: diameter)
            var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
            return CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: &transform)
        }
        return circle.subtracting(hands[0].union(hands[1]))
    }

    /// Dashed ring around the clock in the + menu and Mac send menu icons
    /// (`send-menu-send-later-glass`): 12 dashes on a ring at ~0.43 of the
    /// icon, the clock in the middle at ~0.42 of the icon.
    public static func dashPattern(ringDiameter: CGFloat, dashes: Int = 12, dutyCycle: CGFloat = 0.62) -> [CGFloat] {
        let segment = .pi * ringDiameter / CGFloat(dashes)
        return [segment * dutyCycle, segment * (1 - dutyCycle)]
    }
}
