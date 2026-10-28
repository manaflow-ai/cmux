public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A group color as AppKit draws it: by hue in Lawrence's fixed palette, light or dark.
nonisolated extension GroupColor {
    /// The group color closest to an sRGB `0xRRGGBB` color by hue (another
    /// browser's profile color, so an imported profile keeps its look);
    /// grey for colors with almost no saturation.
    public static func nearest(rgb: UInt32) -> GroupColor {
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        guard color.saturationComponent >= 0.15, color.brightnessComponent >= 0.12 else { return .grey }
        let hue = color.hueComponent * 360
        return allCases.filter { $0.hueAndChroma.chroma > 0 }.min { lhs, rhs in
            Self.hueDistance(lhs.hueAndChroma.hue, hue) < Self.hueDistance(rhs.hueAndChroma.hue, hue)
        } ?? .grey
    }

    private static func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let distance = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(distance, 360 - distance)
    }

    /// The color itself: swatches, group lines, sidebar rails.
    public var swatch: NSColor { dynamic(.swatch) }
    /// Chip and label backgrounds that carry text.
    public var fill: NSColor { dynamic(.fill) }
    /// A very light wash behind grouped content.
    public var wash: NSColor { swatch.withAlphaComponent(0.09) }

    /// Where a group color draws: the color itself, or a background that carries text.
    public enum Role: Sendable {
        case swatch
        case fill
    }

    /// The color in its light or dark variant (`swatch`, `fill`), in sRGB.
    public func rgb(_ role: Role, dark: Bool) -> ThemeRGB {
        let (hue, chroma) = hueAndChroma
        let (saturation, brightness): (CGFloat, CGFloat) = switch role {
        case .swatch: dark ? (0.40, 0.68) : (0.42, 0.64)
        case .fill: dark ? (0.34, 0.40) : (0.30, 0.86)
        }
        let color = NSColor(calibratedHue: hue / 360, saturation: saturation * chroma, brightness: brightness, alpha: 1)
        guard let srgb = color.usingColorSpace(.sRGB) else { return ThemeRGB(red: brightness, green: brightness, blue: brightness) }
        return ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    /// Hue in degrees and relative chroma. Grey has no chroma.
    private var hueAndChroma: (hue: CGFloat, chroma: CGFloat) {
        switch self {
        case .grey: (0, 0)
        case .blue: (214, 1)
        case .red: (4, 1)
        case .yellow: (46, 1)
        case .green: (136, 0.9)
        case .pink: (330, 0.95)
        case .purple: (272, 0.9)
        case .cyan: (186, 0.9)
        case .orange: (24, 1)
        }
    }

    private func dynamic(_ role: Role) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(role, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua).nsColor
        }
    }
}
