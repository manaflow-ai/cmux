public import CMUXMobileCore
import Foundation

/// Neutral colors for the shared-sizing chrome: the bounds border, hatch,
/// chip and avatars. Every role derives from the surface it sits on, the
/// terminal theme for the surface overlay or the system background and label
/// for the size sheet, with contrast floors that hold on any theme.
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

    /// Minimum contrast of chip text and avatar glyphs against the fill.
    public static let glyphContrastFloor = 4.5
    /// Minimum contrast of text drawn directly on the background.
    public static let textContrastFloor = 4.5
    /// Minimum contrast of the grid border, chip outline and owner ring.
    public static let lineContrastFloor = 3.0
    /// Minimum contrast that keeps a fill visible against the background.
    public static let fillContrastFloor = 1.2
    /// Minimum contrast that keeps hatch lines visible against the background.
    public static let hatchContrastFloor = 1.3

    /// Share of the foreground mixed into the background for each role.
    static let fillMix = 0.14
    static let hatchMix = 0.22
    static let lineMix = 0.4
    static let glyphMix = 0.72
    static let textMix = 0.72
    /// Headroom above each floor so 8-bit rendering never drops below it.
    static let floorMargin = 0.03

    /// The surface the chrome sits on.
    public let background: RGB
    /// The surface's text color; every role mixes toward it.
    public let foreground: RGB
    /// Chip and avatar fill: subtle, always visibly off the background.
    public let fill: RGB
    /// Chip text and avatar glyphs drawn on ``fill``.
    public let glyph: RGB
    /// Text drawn on ``background``.
    public let text: RGB
    /// Grid border, chip outline and owner ring.
    public let line: RGB
    /// Hatch lines outside the grid.
    public let hatch: RGB

    /// WCAG 2 contrast ratio, 1...21.
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Derives every role by mixing `foreground` into `background` in
    /// gamma-encoded sRGB at a fixed ratio, then moving the result toward
    /// black or white until its contrast floor holds (WCAG 2 relative
    /// luminance). Same rule as the Mac's `BonsplitContrastPalette`.
    public init(background: RGB, foreground: RGB) {
        self.background = background
        self.foreground = foreground
        let fill = Self.ensuring(
            background.mixed(toward: foreground, by: Self.fillMix),
            floor: Self.fillContrastFloor, against: background, toward: foreground
        )
        self.fill = fill
        hatch = Self.ensuring(
            background.mixed(toward: foreground, by: Self.hatchMix),
            floor: Self.hatchContrastFloor, against: background, toward: foreground
        )
        line = Self.ensuring(
            background.mixed(toward: foreground, by: Self.lineMix),
            floor: Self.lineContrastFloor, against: background, toward: foreground
        )
        glyph = Self.ensuring(
            fill.mixed(toward: foreground, by: Self.glyphMix),
            floor: Self.glyphContrastFloor, against: fill, toward: foreground
        )
        text = Self.ensuring(
            background.mixed(toward: foreground, by: Self.textMix),
            floor: Self.textContrastFloor, against: background, toward: foreground
        )
    }

    /// `color`, or the smallest move from it toward black or white that
    /// reaches `floor` against `reference`. It prefers the pole on
    /// `direction`'s side of the reference, and takes the other pole when
    /// that one cannot reach the floor. A floor of 4.58 or less is always
    /// reachable against an opaque color.
    static func ensuring(_ color: RGB, floor: Double, against reference: RGB, toward direction: RGB) -> RGB {
        let target = floor + floorMargin
        if contrastRatio(color, reference) >= target { return color }
        let white = RGB(red: 1, green: 1, blue: 1)
        let black = RGB(red: 0, green: 0, blue: 0)
        let preferred = direction.relativeLuminance >= reference.relativeLuminance ? white : black
        let other = preferred == white ? black : white
        let pole = contrastRatio(preferred, reference) >= target ? preferred : other
        for step in 1...100 {
            let candidate = color.mixed(toward: pole, by: Double(step) / 100)
            if contrastRatio(candidate, reference) >= target { return candidate }
        }
        return pole
    }

    public enum Role: Sendable, CaseIterable {
        case fill, glyph, text, line, hatch
    }

    public func rgb(_ role: Role) -> RGB {
        switch role {
        case .fill: fill
        case .glyph: glyph
        case .text: text
        case .line: line
        case .hatch: hatch
        }
    }

    /// The palette of a terminal theme's background and foreground (the
    /// colors the surface renders), falling back to Monokai per color.
    public init(theme: TerminalTheme) {
        let fallback = TerminalTheme.monokai
        self.init(
            background: RGB(hex: theme.background) ?? RGB(hex: fallback.background) ?? RGB(red: 0, green: 0, blue: 0),
            foreground: RGB(hex: theme.foreground) ?? RGB(hex: fallback.foreground) ?? RGB(red: 1, green: 1, blue: 1)
        )
    }
}
