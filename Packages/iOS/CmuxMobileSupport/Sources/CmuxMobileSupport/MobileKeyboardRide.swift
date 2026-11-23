public import Foundation

/// How a keyboard-following layout moves for one keyboard will-change: the
/// decision `MobileKeyboardTransition.rideKeyboard` animates, kept free of
/// UIKit so a test checks it against the notification's values on any host.
public struct MobileKeyboardRide: Equatable, Sendable {
    /// The motion the layout runs.
    public enum Motion: Equatable, Sendable {
        /// Lay out at once (the notification carried no duration).
        case immediate
        /// The keyboard's own critically damped spring (curve 7).
        case spring(response: TimeInterval)
        /// The notification's duration on its own UIKit curve.
        case timed(duration: TimeInterval, curve: Int)
    }

    /// The UIKit curve value the keyboard posts for its own animation.
    public static let keyboardCurve = 7

    /// On iOS 26 and 27 UIKit moves the keyboard (curve 7) with a critically
    /// damped spring, stiffness 555 and damping 47.1: response
    /// 2 pi / sqrt(555) = 0.2667 s, not a timing function over the notified
    /// 0.383 s (`ConversationViewController.animateAlongsideKeyboard`).
    public static let keyboardSpringResponse: TimeInterval = 0.2667

    // `UIView.AnimationOptions` raw values (UIKit's UIViewAnimationOptions).
    static let allowUserInteraction: UInt = 1 << 1
    static let beginFromCurrentState: UInt = 1 << 2
    static let overrideInheritedDuration: UInt = 1 << 5
    static let overrideInheritedCurve: UInt = 1 << 6
    static let curveShift: UInt = 16

    /// The motion for this keyboard transition.
    public let motion: Motion

    /// The `UIView.AnimationOptions` raw value the ride animates with: always
    /// interruptible and from the drawn position, never inheriting an outer
    /// duration or curve; a timed ride adds its curve (`curve << 16`).
    public let optionsRawValue: UInt

    /// The ride for a will-change's duration and raw curve.
    public init(duration: TimeInterval, curve: Int) {
        var options = Self.allowUserInteraction | Self.beginFromCurrentState
            | Self.overrideInheritedDuration | Self.overrideInheritedCurve
        if duration <= 0 {
            motion = .immediate
        } else if curve == Self.keyboardCurve {
            motion = .spring(response: Self.keyboardSpringResponse)
        } else {
            motion = .timed(duration: duration, curve: curve)
            options |= UInt(max(curve, 0)) << Self.curveShift
        }
        optionsRawValue = options
    }

    /// The ride for a notification's raw `UIKeyboardAnimationDurationUserInfoKey`
    /// and `UIKeyboardAnimationCurveUserInfoKey` values, as UIKit posts them
    /// (`NSNumber`s): a missing duration lays out at once, a missing curve is
    /// ease-in-out (0).
    public init(notifiedDuration: Any?, notifiedCurve: Any?) {
        self.init(duration: Self.duration(notifiedDuration), curve: Self.curve(notifiedCurve))
    }

    /// The duration a notification's raw value carries; 0 when absent.
    public static func duration(_ notified: Any?) -> TimeInterval {
        (notified as? NSNumber)?.doubleValue ?? (notified as? TimeInterval) ?? 0
    }

    /// The raw curve a notification's value carries; ease-in-out (0) when absent.
    public static func curve(_ notified: Any?) -> Int {
        (notified as? NSNumber)?.intValue ?? (notified as? Int) ?? 0
    }

    /// Seconds from the ride's start until the layout settles, given the
    /// keyboard's own motion: the spring's settle for curve 7, else the
    /// notified duration; 0 when it lays out at once.
    public var settleSeconds: TimeInterval {
        switch motion {
        case .immediate: 0
        case let .spring(response): Self.criticallyDampedSettle(response: response)
        case let .timed(duration, _): duration
        }
    }

    /// When a critically damped spring of `response` comes within 0.5 pt of
    /// rest over a `travel`-point move: x(t) = (1 + w t) e^(-w t), w = 2 pi / response.
    public static func criticallyDampedSettle(
        response: TimeInterval, travel: Double = 336, within: Double = 0.5
    ) -> TimeInterval {
        let omega = 2 * Double.pi / response
        var t = 0.0
        let step = 1.0 / 240
        while (1 + omega * t) * exp(-omega * t) * travel > within, t < 5 { t += step }
        return t
    }
}
