public import AppKit

extension NSColor {
    /// Creates a color from a 6-digit hex string (with or without a leading
    /// `#`), or `nil` when the string is not a valid 6-digit hex color.
    public convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b: CGFloat
        if hexSanitized.count == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Whether the color reads as light (relative luminance above 0.5).
    public var isLightColor: Bool {
        luminance > 0.5
    }

    /// The perceptual relative luminance of the color in sRGB, or `0` when the
    /// color cannot be converted to sRGB.
    public var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    /// Returns a darkened copy of the color, reducing brightness by `amount`
    /// (0...1) in HSB space.
    public func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }

    /// The color as a `#`-prefixed, uppercased sRGB hex string. Returns a 6-digit
    /// `#RRGGBB` string, or an 8-digit `#RRGGBBAA` string when `includeAlpha` is
    /// `true`. The inverse of ``init(hex:)``.
    public func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int(red * 255)))
        let greenByte = min(255, max(0, Int(green * 255)))
        let blueByte = min(255, max(0, Int(blue * 255)))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int(alpha * 255)))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}
