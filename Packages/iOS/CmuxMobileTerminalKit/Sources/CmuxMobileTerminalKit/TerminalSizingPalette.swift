public import CMUXMobileCore
import Foundation

/// Neutral colors for the shared-sizing chrome on a terminal surface.
public struct TerminalSizingPalette: Equatable, Sendable {
    /// An opaque gamma-encoded sRGB color, components in 0...1.
    public struct RGB: Equatable, Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#rrggbb` or `rrggbb`.
        public init?(hex: String) {
            guard let rgb = TerminalTheme.rgbComponents(hex) else { return nil }
            self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
        }

        public func mixed(toward other: RGB, by amount: Double) -> RGB {
            let t = min(max(amount, 0), 1)
            return RGB(
                red: red + (other.red - red) * t,
                green: green + (other.green - green) * t,
                blue: blue + (other.blue - blue) * t
            )
        }

        public var relativeLuminance: Double {
            func linear(_ c: Double) -> Double {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    public let background: RGB
    public let foreground: RGB
    public let fill: RGB
    public let glyph: RGB
    public let text: RGB
    public let line: RGB
    public let hatch: RGB

    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // Stub: the separator-token behavior this palette replaces
    // (UIColor.separator in dark mode, #545458 at 60%, over the background).
    public init(background: RGB, foreground: RGB) {
        self.background = background
        self.foreground = foreground
        let separator = RGB(red: 0.33, green: 0.33, blue: 0.345)
        line = background.mixed(toward: separator, by: 0.6)
        fill = background.mixed(toward: separator, by: 0.3)
        hatch = fill
        glyph = RGB(red: 0.6, green: 0.6, blue: 0.62)
        text = glyph
    }

    public init(theme: TerminalTheme) {
        let fallback = TerminalTheme.monokai
        self.init(
            background: RGB(hex: theme.background) ?? RGB(hex: fallback.background) ?? RGB(red: 0, green: 0, blue: 0),
            foreground: RGB(hex: theme.foreground) ?? RGB(hex: fallback.foreground) ?? RGB(red: 1, green: 1, blue: 1)
        )
    }
}
