public import AppKit

/// A snapshot of the four minimal-mode titlebar debug inset values, resolved
/// from `UserDefaults` and clamped into their valid ranges.
///
/// The values tune where the window's left controls and traffic lights sit
/// relative to the tab bar and titlebar. They are debug knobs persisted under
/// the `titlebarDebug.*` defaults keys; the static members on this type own the
/// keys, defaults, valid ranges, and the reading/clamping logic that produces a
/// snapshot. A pure value type with no live coupling, so callers can read a
/// consistent set of insets in one shot.
public struct MinimalModeTitlebarDebugSnapshot: Equatable {
    /// The leading inset of the window's left controls.
    public let leftControlsLeadingInset: Double
    /// The top inset of the window's left controls.
    public let leftControlsTopInset: Double
    /// The traffic-light leading inset measured against the tab bar.
    public let trafficLightTabBarLeadingInset: Double
    /// The traffic-light leading inset measured against the titlebar.
    public let trafficLightTitlebarLeadingInset: Double

    /// Creates a snapshot from already-resolved inset values.
    public init(
        leftControlsLeadingInset: Double,
        leftControlsTopInset: Double,
        trafficLightTabBarLeadingInset: Double,
        trafficLightTitlebarLeadingInset: Double
    ) {
        self.leftControlsLeadingInset = leftControlsLeadingInset
        self.leftControlsTopInset = leftControlsTopInset
        self.trafficLightTabBarLeadingInset = trafficLightTabBarLeadingInset
        self.trafficLightTitlebarLeadingInset = trafficLightTitlebarLeadingInset
    }
}

extension MinimalModeTitlebarDebugSnapshot {
    /// Defaults key for the left controls' leading inset.
    public static let leftControlsLeadingInsetKey = "titlebarDebug.leftControlsLeadingInset"
    /// Defaults key for the left controls' top inset.
    public static let leftControlsTopInsetKey = "titlebarDebug.leftControlsTopInset"
    /// Defaults key for the traffic-light inset against the tab bar.
    public static let trafficLightTabBarInsetKey = "titlebarDebug.trafficLightTabBarInset"
    /// Defaults key for the traffic-light inset against the titlebar.
    public static let trafficLightTitlebarLeadingInsetKey = "titlebarDebug.trafficLightTitlebarLeadingInset"

    /// Fallback for ``leftControlsLeadingInset`` when nothing is stored.
    public static let defaultLeftControlsLeadingInset = 72.0
    /// Fallback for ``leftControlsTopInset`` when nothing is stored.
    public static let defaultLeftControlsTopInset = 2.0
    /// Fallback for ``trafficLightTabBarLeadingInset`` when nothing is stored.
    public static let defaultTrafficLightTabBarInset = 80.0
    /// Fallback for ``trafficLightTitlebarLeadingInset`` when nothing is stored.
    public static let defaultTrafficLightTitlebarLeadingInset = 78.0

    /// Valid range for the horizontal inset knobs.
    public static let horizontalInsetRange: ClosedRange<Double> = 0...180
    /// Valid range for the top inset knob.
    public static let topInsetRange: ClosedRange<Double> = -8...32
    /// Valid range for the left controls' x-offset, derived from the horizontal
    /// range and the default leading inset.
    public static let leftControlsXOffsetRange: ClosedRange<Double> = (
        horizontalInsetRange.lowerBound - defaultLeftControlsLeadingInset
    )...(
        horizontalInsetRange.upperBound - defaultLeftControlsLeadingInset
    )

    /// Clamps `value` into `range`.
    public static func clamped(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Resolves the traffic-light leading inset against the tab bar.
    public static func trafficLightTabBarLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: trafficLightTabBarInsetKey,
                fallback: defaultTrafficLightTabBarInset,
                range: horizontalInsetRange
            )
        )
    }

    /// Resolves the traffic-light leading inset against the titlebar.
    public static func trafficLightTitlebarLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: trafficLightTitlebarLeadingInsetKey,
                fallback: defaultTrafficLightTitlebarLeadingInset,
                range: horizontalInsetRange
            )
        )
    }

    /// Resolves the left controls' leading inset.
    public static func leftControlsLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: leftControlsLeadingInsetKey,
                fallback: defaultLeftControlsLeadingInset,
                range: horizontalInsetRange
            )
        )
    }

    /// Resolves the left controls' top inset.
    public static func leftControlsTopInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: leftControlsTopInsetKey,
                fallback: defaultLeftControlsTopInset,
                range: topInsetRange
            )
        )
    }

    /// Converts a leading inset into an x-offset relative to the default,
    /// clamped into ``leftControlsXOffsetRange``.
    public static func leftControlsXOffset(leadingInset: Double) -> CGFloat {
        CGFloat(
            clamped(
                leadingInset - defaultLeftControlsLeadingInset,
                range: leftControlsXOffsetRange
            )
        )
    }

    /// Reads all four insets from `defaults` into a single snapshot.
    public static func snapshot(defaults: UserDefaults = .standard) -> MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: Double(leftControlsLeadingInset(defaults: defaults)),
            leftControlsTopInset: Double(leftControlsTopInset(defaults: defaults)),
            trafficLightTabBarLeadingInset: Double(trafficLightTabBarLeadingInset(defaults: defaults)),
            trafficLightTitlebarLeadingInset: Double(trafficLightTitlebarLeadingInset(defaults: defaults))
        )
    }

    private static func storedDouble(
        defaults: UserDefaults,
        key: String,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let rawValue: Double?
        if let value = defaults.object(forKey: key) as? NSNumber {
            rawValue = value.doubleValue
        } else if let value = defaults.string(forKey: key) {
            rawValue = Double(value)
        } else {
            rawValue = nil
        }
        guard let rawValue, rawValue.isFinite else {
            return fallback
        }
        return clamped(rawValue, range: range)
    }
}
