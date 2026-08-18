import Foundation

/// A color in CIE L\*a\*b\*, used to compare how different two rail colors
/// actually look.
///
/// Rail colors are compared as they are *rendered*, so this applies the same
/// dark-appearance brightening as
/// `WorkspaceTabColorSettings.displayNSColor(hex:colorScheme:forceBright:)`.
/// Comparing raw hexes would understate the distance between dark colors that
/// brighten to very different results.
///
/// Deliberately AppKit-free so color allocation stays unit-testable, which is
/// also why the sRGB → Lab conversion is spelled out here instead of going
/// through `NSColor`.
struct LabColor: Equatable {
    let l: Double
    let a: Double
    let b: Double

    init?(hex: String) {
        guard let rgb = Self.sRGB(hex: hex) else { return nil }
        let brightened = Self.brightenedForDarkAppearance(rgb)
        self = Self.lab(from: brightened)
    }

    /// CIE76 ΔE. Roughly: < 2.3 is imperceptible, and a 3pt rail needs ~10 to
    /// read as a different color at a glance.
    func distance(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    // MARK: - Conversion

    /// Parses the canonical `#RRGGBB` form produced by
    /// `WorkspaceTabColorSettings.normalizedHex(_:)`.
    ///
    /// Shorthand `#RGB` is rejected on purpose: that helper rejects it too, so
    /// a three-digit color can never reach the sidebar. Accepting it here would
    /// let a color that cannot be rendered still pull allocation around.
    private static func sRGB(hex: String) -> (Double, Double, Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    // MARK: - Dark appearance brightening

    /// The dark-appearance brightening rule, shared with
    /// `WorkspaceTabColorSettings.brightenedForDarkAppearance`.
    ///
    /// The constants live in this file, rather than beside the `NSColor`
    /// implementation that renders with them, because this is the AppKit-free
    /// side and allocation has to compare colors the way they will actually be
    /// drawn. A constant that drifted between the two would leave allocation
    /// spacing out colors nobody ever sees.
    static let darkBrightnessFloor = 0.62
    static let darkBrightnessLift = 0.28
    /// Saturation at or below this is left untouched, so neutral grays do not
    /// pick up a hue when brightened.
    static let neutralSaturationCeiling = 0.08
    static let darkSaturationLift = 0.12

    private static func brightenedForDarkAppearance(
        _ rgb: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        let (hue, saturation, brightness) = hsv(from: rgb)
        let boostedBrightness = min(
            1,
            max(brightness, darkBrightnessFloor) + ((1 - brightness) * darkBrightnessLift)
        )
        let boostedSaturation = saturation <= neutralSaturationCeiling
            ? saturation
            : min(1, saturation + ((1 - saturation) * darkSaturationLift))
        return self.rgb(hue: hue, saturation: boostedSaturation, brightness: boostedBrightness)
    }

    private static func hsv(from rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = rgb
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        guard delta > 0, maxValue > 0 else { return (0, 0, maxValue) }

        var hue: Double
        switch maxValue {
        case r: hue = (g - b) / delta
        case g: hue = 2 + (b - r) / delta
        default: hue = 4 + (r - g) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxValue, maxValue)
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (Double, Double, Double) {
        guard saturation > 0 else { return (brightness, brightness, brightness) }
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector)
        let fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    private static func lab(from rgb: (Double, Double, Double)) -> LabColor {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.0)
        let g = linear(rgb.1)
        let b = linear(rgb.2)

        // sRGB → XYZ, normalized to the D65 white point.
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883

        func pivot(_ value: Double) -> Double {
            value > 0.008856 ? pow(value, 1.0 / 3.0) : (7.787 * value) + (16.0 / 116.0)
        }
        let fx = pivot(x)
        let fy = pivot(y)
        let fz = pivot(z)

        return LabColor(
            l: (116 * fy) - 16,
            a: 500 * (fx - fy),
            b: 200 * (fy - fz)
        )
    }

    private init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}
