public import AppKit

/// An sRGB color as plain values, so theme derivation is pure, testable and
/// thread-safe. Components are 0...1.
public nonisolated struct ThemeRGB: Hashable, Sendable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 8-bit components, as Ghostty reports them.
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    public static let black = ThemeRGB(red: 0, green: 0, blue: 0)
    public static let white = ThemeRGB(red: 1, green: 1, blue: 1)

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
    public func contrast(with other: ThemeRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Linear sRGB mix: `fraction` 0 is self, 1 is `other`. Alpha is kept.
    public func mixed(toward other: ThemeRGB, _ fraction: Double) -> ThemeRGB {
        let t = Self.clamp(fraction)
        return ThemeRGB(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha
        )
    }

    public func withAlpha(_ alpha: Double) -> ThemeRGB {
        ThemeRGB(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The opaque color seen when this (possibly translucent) color is
    /// painted over `base`.
    public func composited(over base: ThemeRGB) -> ThemeRGB {
        base.mixed(toward: withAlpha(1), alpha).withAlpha(1)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
