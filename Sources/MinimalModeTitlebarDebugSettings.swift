import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode titlebar debug settings
enum MinimalModeTitlebarDebugSettings {
    static let leftControlsLeadingInsetKey = "titlebarDebug.leftControlsLeadingInset"
    static let leftControlsTopInsetKey = "titlebarDebug.leftControlsTopInset"
    static let trafficLightTabBarInsetKey = "titlebarDebug.trafficLightTabBarInset"
    static let trafficLightTitlebarLeadingInsetKey = "titlebarDebug.trafficLightTitlebarLeadingInset"

    static let defaultLeftControlsLeadingInset = 72.0
    static let defaultLeftControlsTopInset = 2.0
    static let defaultTrafficLightTabBarInset = 80.0
    static let defaultTrafficLightTitlebarLeadingInset = 78.0

    static let horizontalInsetRange: ClosedRange<Double> = 0...180
    static let topInsetRange: ClosedRange<Double> = -8...32
    private static let leftControlsXOffsetRange: ClosedRange<Double> = (
        horizontalInsetRange.lowerBound - defaultLeftControlsLeadingInset
    )...(
        horizontalInsetRange.upperBound - defaultLeftControlsLeadingInset
    )

    static func clamped(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func trafficLightTabBarLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: trafficLightTabBarInsetKey,
                fallback: defaultTrafficLightTabBarInset,
                range: horizontalInsetRange
            )
        )
    }

    static func trafficLightTitlebarLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: trafficLightTitlebarLeadingInsetKey,
                fallback: defaultTrafficLightTitlebarLeadingInset,
                range: horizontalInsetRange
            )
        )
    }

    static func leftControlsLeadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: leftControlsLeadingInsetKey,
                fallback: defaultLeftControlsLeadingInset,
                range: horizontalInsetRange
            )
        )
    }

    static func leftControlsTopInset(defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            storedDouble(
                defaults: defaults,
                key: leftControlsTopInsetKey,
                fallback: defaultLeftControlsTopInset,
                range: topInsetRange
            )
        )
    }

    static func leftControlsXOffset(leadingInset: Double) -> CGFloat {
        CGFloat(
            clamped(
                leadingInset - defaultLeftControlsLeadingInset,
                range: leftControlsXOffsetRange
            )
        )
    }

    static func snapshot(defaults: UserDefaults = .standard) -> MinimalModeTitlebarDebugSnapshot {
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

struct MinimalModeTitlebarDebugSnapshot: Equatable {
    let leftControlsLeadingInset: Double
    let leftControlsTopInset: Double
    let trafficLightTabBarLeadingInset: Double
    let trafficLightTitlebarLeadingInset: Double
}

