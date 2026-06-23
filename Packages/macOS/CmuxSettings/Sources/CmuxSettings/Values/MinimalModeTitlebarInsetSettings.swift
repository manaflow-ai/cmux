public import Foundation

/// UserDefaults keys, defaults, clamp ranges, and stored-value readers for the
/// four minimal-mode titlebar debug insets that drive the custom window chrome.
///
/// This is the settings home for the inset keys that previously lived as
/// `@AppStorage` declarations on `ContentView` (and as the `static let` key
/// strings on the app-target `MinimalModeTitlebarDebugSettings` namespace). The
/// key strings, defaults, ranges, and the clamp/decode behavior are lifted
/// byte-identically so the wire/Defaults format is unchanged; the window-chrome
/// owner (`CmuxWindowing.WindowChromeController`) reads these instead of the
/// app-target enum.
public enum MinimalModeTitlebarInsetSettings {
    /// Persisted key for the minimal-mode left titlebar controls leading inset.
    public static let leftControlsLeadingInsetKey = "titlebarDebug.leftControlsLeadingInset"
    /// Persisted key for the minimal-mode left titlebar controls top inset.
    public static let leftControlsTopInsetKey = "titlebarDebug.leftControlsTopInset"
    /// Persisted key for the traffic-light-to-tab-bar leading inset.
    public static let trafficLightTabBarInsetKey = "titlebarDebug.trafficLightTabBarInset"
    /// Persisted key for the traffic-light titlebar leading inset.
    public static let trafficLightTitlebarLeadingInsetKey = "titlebarDebug.trafficLightTitlebarLeadingInset"

    /// Default left titlebar controls leading inset.
    public static let defaultLeftControlsLeadingInset = 72.0
    /// Default left titlebar controls top inset.
    public static let defaultLeftControlsTopInset = 2.0
    /// Default traffic-light-to-tab-bar leading inset.
    public static let defaultTrafficLightTabBarInset = 80.0
    /// Default traffic-light titlebar leading inset.
    public static let defaultTrafficLightTitlebarLeadingInset = 78.0

    /// Allowed range for horizontal insets.
    public static let horizontalInsetRange: ClosedRange<Double> = 0...180
    /// Allowed range for the top inset.
    public static let topInsetRange: ClosedRange<Double> = -8...32
    /// Allowed range for the left controls X offset derived from the leading inset.
    public static let leftControlsXOffsetRange: ClosedRange<Double> = (
        horizontalInsetRange.lowerBound - defaultLeftControlsLeadingInset
    )...(
        horizontalInsetRange.upperBound - defaultLeftControlsLeadingInset
    )

    /// Clamps `value` into `range`.
    public static func clamped(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Reads the traffic-light-to-tab-bar leading inset from defaults.
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

    /// Reads the traffic-light titlebar leading inset from defaults.
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

    /// Reads the left titlebar controls leading inset from defaults.
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

    /// Reads the left titlebar controls top inset from defaults.
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

    /// Derives the left controls X offset from a leading inset.
    public static func leftControlsXOffset(leadingInset: Double) -> CGFloat {
        CGFloat(
            clamped(
                leadingInset - defaultLeftControlsLeadingInset,
                range: leftControlsXOffsetRange
            )
        )
    }

    /// Reads a clamped finite Double from defaults, accepting either an
    /// `NSNumber` or a numeric `String`, falling back to `fallback` otherwise.
    public static func storedDouble(
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

/// Immutable snapshot of the four resolved minimal-mode titlebar insets.
public struct MinimalModeTitlebarInsetSnapshot: Sendable, Equatable {
    /// Left titlebar controls leading inset.
    public var leftControlsLeadingInset: Double
    /// Left titlebar controls top inset.
    public var leftControlsTopInset: Double
    /// Traffic-light-to-tab-bar leading inset.
    public var trafficLightTabBarLeadingInset: Double
    /// Traffic-light titlebar leading inset.
    public var trafficLightTitlebarLeadingInset: Double

    /// Creates a snapshot from explicit inset values.
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
