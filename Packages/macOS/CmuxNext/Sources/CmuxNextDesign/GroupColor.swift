public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// The nine group colors, shared by tab groups and workspace groups so
/// both render identically. The raw value is the stable token the daemon
/// stores and `cmux.json` / the CLI accept.
///
/// Group colors are user content, so blue is allowed here (the no-blue rule
/// covers app chrome). Every token is one hue at low saturation, tuned so a
/// window full of groups still reads as calm gray chrome.
public nonisolated enum GroupColor: String, CaseIterable, Codable, Hashable, Sendable {
    case grey
    case blue
    case red
    case yellow
    case green
    case pink
    case purple
    case cyan
    case orange

    /// The color a new group, space or browser profile gets: the first of
    /// `automaticOrder` not in `used`; never blue or grey. Nil when every
    /// such color is in use.
    public static func automatic(used: Set<String>) -> GroupColor? {
        automaticOrder.first { !used.contains($0.rawValue) }
    }

    /// The color a group with no stored color draws in: one of `automaticOrder`, picked from
    /// the group's id, so it is the same on every launch and machine (Leo 2026-10-20: groups
    /// made by agents and the CLI store none and all drew grey, as Chrome never does). A
    /// group someone colored grey keeps grey; only a missing color takes this.
    public static func unset(id: String) -> GroupColor {
        // FNV-1a: `hashValue` is seeded per process, so it would change the color each launch.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return automaticOrder[Int(hash % UInt64(automaticOrder.count))]
    }

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
