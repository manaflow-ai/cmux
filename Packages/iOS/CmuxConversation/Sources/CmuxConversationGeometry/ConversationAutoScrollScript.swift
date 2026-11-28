import CoreGraphics
import Foundation

/// A scripted transcript scroll for the DEBUG lab
/// (`CMUX_UITEST_CONVERSATION_AUTOSCROLL`): drags, flicks that decelerate
/// as a scroll view does, and idle holds, run from a display link so a
/// scroll trace records the same motion before and after a change.
///
/// Script syntax, comma separated: `hold:<seconds>`,
/// `drag:<points>:<seconds>`, `flick:<points per second>`, and a leading
/// `repeat:<count>`. Positive distances and velocities move up into
/// history (the content offset decreases). `default` names `standard`.
public struct ConversationAutoScrollScript: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// No motion; the transcript rests.
        case hold(seconds: Double)
        /// A finger drag of `points`, eased in and out over `seconds`.
        case drag(points: CGFloat, seconds: Double)
        /// A release at `velocity`, decelerating at the normal rate.
        case flick(velocity: CGFloat)

        public struct Progress: Equatable, Sendable {
            /// Points moved since the step began (positive into history).
            public var distance: CGFloat
            public var finished: Bool

            public init(distance: CGFloat, finished: Bool) {
                self.distance = distance
                self.finished = finished
            }
        }

        /// UIScrollView's normal deceleration, per millisecond.
        public static let decelerationRate: Double = 0.998
        /// A flick ends once it is slower than this (points per second).
        static let restingVelocity: Double = 5

        /// Where the step is `elapsed` seconds after it began.
        public func progress(at elapsed: Double) -> Progress {
            let t = max(0, elapsed)
            switch self {
            case let .hold(seconds):
                return Progress(distance: 0, finished: t >= seconds)
            case let .drag(points, seconds):
                guard seconds > 0, t < seconds else { return Progress(distance: points, finished: true) }
                let x = t / seconds
                let eased = x * x * (3 - 2 * x)
                return Progress(distance: points * CGFloat(eased), finished: false)
            case let .flick(velocity):
                let v0 = Double(velocity)
                let k = 1000 * log(1 / Self.decelerationRate)
                let total = v0 / k
                let speed = abs(v0) * exp(-k * t)
                guard speed > Self.restingVelocity else { return Progress(distance: CGFloat(total), finished: true) }
                return Progress(distance: CGFloat(total * (1 - exp(-k * t))), finished: false)
            }
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// Settles at the bottom, drags slowly up, flicks up into history
    /// twice, holds, flicks back down to the newest message and rests there
    /// (where a typing indicator or arrival animates), twice over.
    public static let standard = ConversationAutoScrollScript(steps: Array(repeating: [
        Step.hold(seconds: 2),
        .drag(points: 240, seconds: 1.2),
        .hold(seconds: 0.5),
        .drag(points: 160, seconds: 0.4),
        .flick(velocity: 2800),
        .hold(seconds: 1),
        .flick(velocity: 4500),
        .hold(seconds: 2),
        .drag(points: -200, seconds: 0.5),
        .flick(velocity: -5200),
        .flick(velocity: -6000),
        .hold(seconds: 3),
    ], count: 2).flatMap { $0 })

    /// Parses a script, or nil when any step is malformed.
    public init?(parsing text: String) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts == ["default"] {
            self = Self.standard
            return
        }
        var repeats = 1
        var steps: [Step] = []
        for (index, part) in parts.enumerated() {
            let fields = part.split(separator: ":").map(String.init)
            func number(_ i: Int) -> Double? { i < fields.count ? Double(fields[i]) : nil }
            switch fields.first {
            case "repeat" where index == 0 && fields.count == 2:
                guard let count = number(1), count >= 1 else { return nil }
                repeats = Int(count)
            case "hold" where fields.count == 2:
                guard let seconds = number(1), seconds >= 0 else { return nil }
                steps.append(.hold(seconds: seconds))
            case "drag" where fields.count == 3:
                guard let points = number(1), let seconds = number(2), seconds > 0 else { return nil }
                steps.append(.drag(points: CGFloat(points), seconds: seconds))
            case "flick" where fields.count == 2:
                guard let velocity = number(1) else { return nil }
                steps.append(.flick(velocity: CGFloat(velocity)))
            default:
                return nil
            }
        }
        guard !steps.isEmpty else { return nil }
        self.steps = Array(repeating: steps, count: repeats).flatMap { $0 }
    }
}
