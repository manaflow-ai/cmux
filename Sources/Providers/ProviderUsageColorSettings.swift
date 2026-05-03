import Bonsplit
import SwiftUI

// MARK: - Color Settings

@MainActor
final class ProviderUsageColorSettings: ObservableObject {
    static let shared = ProviderUsageColorSettings()

    private static let keyLow = "cmux.provider.usageColor.low"
    private static let keyMid = "cmux.provider.usageColor.mid"
    private static let keyHigh = "cmux.provider.usageColor.high"
    private static let keyLowMidThreshold = "cmux.provider.usageColor.lowMidThreshold"
    private static let keyMidHighThreshold = "cmux.provider.usageColor.midHighThreshold"
    private static let keyInterpolate = "cmux.provider.usageColor.interpolate"

    static let defaultLowHex = "#46B46E"
    static let defaultMidHex = "#D2AA3C"
    static let defaultHighHex = "#DC5050"

    /// Resolved `Color` value for each built-in threshold color. Kept as
    /// derived constants so the Settings color pickers, the live preview, and
    /// `color(for:)` all use the exact same fallback when a persisted hex
    /// value fails to parse.
    static var defaultLowColor: Color { Color(usageHex: defaultLowHex) ?? .green }
    static var defaultMidColor: Color { Color(usageHex: defaultMidHex) ?? .yellow }
    static var defaultHighColor: Color { Color(usageHex: defaultHighHex) ?? .red }
    private static let defaultLowMidThreshold = 85
    private static let defaultMidHighThreshold = 95

    private let defaults: UserDefaults

    @Published var lowColorHex: String {
        didSet { defaults.set(lowColorHex, forKey: Self.keyLow) }
    }

    @Published var midColorHex: String {
        didSet { defaults.set(midColorHex, forKey: Self.keyMid) }
    }

    @Published var highColorHex: String {
        didSet { defaults.set(highColorHex, forKey: Self.keyHigh) }
    }

    /// Writes are funneled through `setThresholds(low:high:)` so the `1...99`
    /// contract and the `low < high` ordering invariant can be enforced in one
    /// place. Direct external writes are disallowed to keep out-of-range or
    /// inverted pairs from bypassing that validation.
    @Published private(set) var lowMidThreshold: Int {
        didSet { defaults.set(lowMidThreshold, forKey: Self.keyLowMidThreshold) }
    }

    @Published private(set) var midHighThreshold: Int {
        didSet { defaults.set(midHighThreshold, forKey: Self.keyMidHighThreshold) }
    }

    @Published var interpolate: Bool {
        didSet { defaults.set(interpolate, forKey: Self.keyInterpolate) }
    }

    private convenience init() {
        self.init(userDefaults: .standard)
    }

    /// Test-only initializer. Keeps production code on `.shared` but lets
    /// `cmuxTests/ProviderTests.swift` point the settings at an isolated
    /// `UserDefaults` suite so it never pollutes or reads from the user's
    /// real defaults domain.
    init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        self.lowColorHex = userDefaults.string(forKey: Self.keyLow) ?? Self.defaultLowHex
        self.midColorHex = userDefaults.string(forKey: Self.keyMid) ?? Self.defaultMidHex
        self.highColorHex = userDefaults.string(forKey: Self.keyHigh) ?? Self.defaultHighHex

        var lowMid = (userDefaults.object(forKey: Self.keyLowMidThreshold) as? Int) ?? Self.defaultLowMidThreshold
        var midHigh = (userDefaults.object(forKey: Self.keyMidHighThreshold) as? Int) ?? Self.defaultMidHighThreshold
        lowMid = min(max(lowMid, 1), 98)
        midHigh = min(max(midHigh, 2), 99)
        if lowMid >= midHigh {
            lowMid = Self.defaultLowMidThreshold
            midHigh = Self.defaultMidHighThreshold
        }
        self.lowMidThreshold = lowMid
        self.midHighThreshold = midHigh

        if userDefaults.object(forKey: Self.keyInterpolate) != nil {
            self.interpolate = userDefaults.bool(forKey: Self.keyInterpolate)
        } else {
            self.interpolate = true
        }
    }

    // MARK: - Color Resolution

    func color(for percent: Int) -> Color {
        let clamped = min(max(percent, 0), 100)
        let lowColor = Color(usageHex: lowColorHex) ?? Self.defaultLowColor
        let midColor = Color(usageHex: midColorHex) ?? Self.defaultMidColor
        let highColor = Color(usageHex: highColorHex) ?? Self.defaultHighColor

        if !interpolate {
            if clamped <= lowMidThreshold {
                return lowColor
            } else if clamped <= midHighThreshold {
                return midColor
            } else {
                return highColor
            }
        }

        // Interpolation mode
        if clamped <= lowMidThreshold {
            let t = lowMidThreshold > 0
                ? Double(clamped) / Double(lowMidThreshold)
                : 0.0
            return interpolateColor(from: lowColor, to: midColor, t: t)
        } else if clamped <= midHighThreshold {
            let range = midHighThreshold - lowMidThreshold
            let t = range > 0
                ? Double(clamped - lowMidThreshold) / Double(range)
                : 0.0
            return interpolateColor(from: midColor, to: highColor, t: t)
        } else {
            return highColor
        }
    }

    // MARK: - Threshold Validation

    func setThresholds(low: Int, high: Int) {
        guard low >= 1, high <= 99, low < high else { return }
        lowMidThreshold = low
        midHighThreshold = high
    }

    // MARK: - Reset

    func resetToDefaults() {
        lowColorHex = Self.defaultLowHex
        midColorHex = Self.defaultMidHex
        highColorHex = Self.defaultHighHex
        setThresholds(low: Self.defaultLowMidThreshold, high: Self.defaultMidHighThreshold)
        interpolate = true
    }

    // MARK: - Color Interpolation

    private func interpolateColor(from: Color, to: Color, t: Double) -> Color {
        let clampedT = min(max(t, 0), 1)
        let fromComponents = from.rgbComponents
        let toComponents = to.rgbComponents
        return Color(
            red: fromComponents.red + (toComponents.red - fromComponents.red) * clampedT,
            green: fromComponents.green + (toComponents.green - fromComponents.green) * clampedT,
            blue: fromComponents.blue + (toComponents.blue - fromComponents.blue) * clampedT
        )
    }
}

// MARK: - Color Hex Extension

extension Color {
    init?(usageHex hex: String) {
        // Accept exactly zero or one leading `#`. `trimmingCharacters` would
        // have silently normalized junk like `###RRGGBB` or `#RRGGBB#`;
        // requiring a tight shape lets corrupted persisted colors fail closed.
        let sanitized: String
        if hex.hasPrefix("#") {
            sanitized = String(hex.dropFirst())
        } else {
            sanitized = hex
        }
        guard sanitized.count == 6, let value = UInt64(sanitized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var usageHexString: String {
        let components = rgbComponents
        let r = Int(round(components.red * 255))
        let g = Int(round(components.green * 255))
        let b = Int(round(components.blue * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Returns the sRGB red/green/blue components of this color in the 0...1 range.
    ///
    /// If the color cannot be converted to the sRGB color space (for example, pattern
    /// colors or asset-catalog dynamic colors that lack a concrete sRGB representation),
    /// this falls back to opaque black `(0, 0, 0)`.
    var rgbComponents: (red: Double, green: Double, blue: Double) {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            #if DEBUG
            dlog("[ProviderUsageColorSettings] rgbComponents: color is not sRGB-convertible, falling back to black.")
            #endif
            return (red: 0, green: 0, blue: 0)
        }
        return (
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent)
        )
    }
}
