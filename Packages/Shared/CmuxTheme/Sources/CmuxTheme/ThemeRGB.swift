import Foundation

/// An sRGB color as plain values, so theme derivation is pure, testable and
/// thread-safe. Components are 0...1.
public struct ThemeRGB: Hashable, Sendable, CustomStringConvertible {
    /// Red, 0...1.
    public var red: Double
    /// Green, 0...1.
    public var green: Double
    /// Blue, 0...1.
    public var blue: Double
    /// Opacity, 0...1.
    public var alpha: Double

    /// A color from 0...1 components; values outside the range are clamped.
    ///
    /// - Parameters:
    ///   - red: Red, 0...1.
    ///   - green: Green, 0...1.
    ///   - blue: Blue, 0...1.
    ///   - alpha: Opacity, 0...1; opaque by default.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// A color from `0xRRGGBB`.
    ///
    /// - Parameters:
    ///   - hex: The color as `0xRRGGBB`.
    ///   - alpha: Opacity, 0...1; opaque by default.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// An opaque color from 8-bit components, as Ghostty reports them.
    ///
    /// - Parameters:
    ///   - r: Red, 0...255.
    ///   - g: Green, 0...255.
    ///   - b: Blue, 0...255.
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// A color from `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional), as
    /// cmux.json colors are written.
    ///
    /// - Parameter text: The hex color.
    /// - Returns: Nil for anything else.
    public init?(cssHex text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), var value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 3 {
            let r = (value >> 8) & 0xF, g = (value >> 4) & 0xF, b = value & 0xF
            value = (r * 17) << 16 | (g * 17) << 8 | b * 17
        }
        let alpha = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
        if digits.count == 8 { value >>= 8 }
        self.init(hex: UInt32(value), alpha: alpha)
    }

    /// Opaque black.
    public static let black = ThemeRGB(red: 0, green: 0, blue: 0)
    /// Opaque white.
    public static let white = ThemeRGB(red: 1, green: 1, blue: 1)

    /// `#RRGGBB`, with `@alpha` appended when the color is translucent.
    public var description: String {
        let hex = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        return alpha < 1 ? "\(hex)@\(String(format: "%.2f", alpha))" : hex
    }

    /// WCAG 2 relative luminance of the opaque color.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio between two opaque colors (1...21).
    ///
    /// - Parameter other: The color to compare with.
    /// - Returns: The ratio, 1 (no contrast) to 21 (black on white).
    public func contrast(with other: ThemeRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear sRGB mix: `fraction` 0 is self, 1 is `other`. Alpha is kept.
    ///
    /// - Parameters:
    ///   - other: The color to mix toward.
    ///   - fraction: How far, 0...1.
    /// - Returns: The mixed color, at this color's opacity.
    public func mixed(toward other: ThemeRGB, _ fraction: Double) -> ThemeRGB {
        let t = Self.clamp(fraction)
        return ThemeRGB(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha
        )
    }

    /// This color with `alpha` as its opacity.
    ///
    /// - Parameter alpha: Opacity, 0...1.
    /// - Returns: The same color at that opacity.
    public func withAlpha(_ alpha: Double) -> ThemeRGB {
        ThemeRGB(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The opaque color seen when this (possibly translucent) color is
    /// painted over `base`.
    ///
    /// - Parameter base: The color underneath; its own opacity is ignored.
    /// - Returns: The opaque result.
    public func composited(over base: ThemeRGB) -> ThemeRGB {
        base.mixed(toward: withAlpha(1), alpha).withAlpha(1)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
