import Foundation

/// A platform-neutral sRGB color used by the token resolver.
///
/// Hex input accepts `#RRGGBB`, `RRGGBB`, `#RRGGBBAA`, and `RRGGBBAA`.
/// Three-digit CSS shorthand is intentionally rejected so malformed config
/// values fail closed instead of being silently interpreted differently by
/// different color APIs.
public struct ChromeColor: Sendable, Equatable, Hashable {
    /// Red sRGB component in the closed interval `0...1`.
    public let red: Double
    /// Green sRGB component in the closed interval `0...1`.
    public let green: Double
    /// Blue sRGB component in the closed interval `0...1`.
    public let blue: Double
    /// Alpha component in the closed interval `0...1`.
    public let alpha: Double

    /// Creates a color, clamping each component to the valid sRGB range.
    ///
    /// - Parameters:
    ///   - red: Red sRGB component.
    ///   - green: Green sRGB component.
    ///   - blue: Blue sRGB component.
    ///   - alpha: Optional opacity; defaults to fully opaque.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Creates a color from a six- or eight-digit hexadecimal string.
    ///
    /// - Parameter hex: `#RRGGBB`, `RRGGBB`, `#RRGGBBAA`, or `RRGGBBAA`.
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }),
              let raw = UInt64(value, radix: 16) else { return nil }
        let divisor = 255.0
        let red = Double((raw >> (value.count == 8 ? 24 : 16)) & 0xFF) / divisor
        let green = Double((raw >> (value.count == 8 ? 16 : 8)) & 0xFF) / divisor
        let blue = Double((raw >> (value.count == 8 ? 8 : 0)) & 0xFF) / divisor
        let alpha = value.count == 8 ? Double(raw & 0xFF) / divisor : 1
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Uppercase, six- or eight-digit representation suitable for config.
    public var hex: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let base = String(format: "%02X%02X%02X", channels[0], channels[1], channels[2])
        guard channels[3] < 255 else { return "#\(base)" }
        return String(format: "#%@%02X", base, channels[3])
    }

    /// WCAG relative luminance for this color after compositing transparency
    /// over an opaque background.
    ///
    /// When no background is supplied, transparency is composited over white.
    /// Callers that know the underlying surface should pass it explicitly.
    public func relativeLuminance(over background: ChromeColor? = nil) -> Double {
        let composited: ChromeColor
        if let background {
            composited = opaqueColor(over: background)
        } else if alpha < 1 {
            composited = opaqueColor(over: .white)
        } else {
            composited = self
        }
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(composited.red)
            + 0.7152 * linear(composited.green)
            + 0.0722 * linear(composited.blue)
    }

    /// Returns the WCAG contrast ratio when this color is rendered over `background`.
    ///
    /// Both colors are first composited to opaque sRGB values, so translucent
    /// user overrides cannot accidentally pass the contrast check by comparing
    /// their uncomposited channel values.
    ///
    /// - Parameters:
    ///   - background: The surface behind this color.
    ///   - underlying: An optional surface behind a translucent background.
    ///     When omitted, white is used as the final compositing surface.
    public func contrastRatio(
        with background: ChromeColor,
        underlying: ChromeColor? = nil
    ) -> Double {
        let finalSurface = underlying.map { $0.opaqueColor(over: .white) } ?? .white
        let opaqueBackground = background.opaqueColor(over: finalSurface)
        let foregroundLuminance = opaqueColor(over: opaqueBackground).relativeLuminance()
        let backgroundLuminance = opaqueBackground.relativeLuminance()
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Opaque black used by contrast fallback calculations.
    public static let black = ChromeColor(red: 0, green: 0, blue: 0)
    /// Opaque white used by contrast fallback calculations.
    public static let white = ChromeColor(red: 1, green: 1, blue: 1)

    /// Composites this color over `background` and returns an opaque result.
    func opaqueColor(over background: ChromeColor) -> ChromeColor {
        let a = alpha
        return ChromeColor(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
