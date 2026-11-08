public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// The nine group colors, shared by tab groups and workspace groups so
/// both render identically. The raw value is the stable token the daemon
/// stores and `cmux.json` / the CLI accept.
///
/// Group colors are user content, so blue is allowed here (the no-blue rule
/// covers app chrome). The tokens draw the vibrant palette (``GroupPalette/vibrant``): clean,
/// bright colors that read as color on dark and light glass. They replace the low-saturation set
/// that went brown and olive under a dark veil (Leo 2026-11-06: "these are ugly-ass colors,
/// bro. These are frumpy"); a sidebar group draws its token from the chosen palette
/// (`GroupColor.paletteRGB`).
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

    /// The color a new space or browser profile gets: the first of
    /// `automaticOrder` not in `used`; never blue or grey. Nil when every
    /// such color is in use. Groups get none: no color until a person picks one.
    public static func automatic(used: Set<String>) -> GroupColor? {
        automaticOrder.first { !used.contains($0.rawValue) }
    }

    /// A stable palette color for an unbranded harness or session mark. Groups with no
    /// user-chosen color use `GroupTint.none` and never call this fallback.
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

    /// The color in its light or dark variant (`swatch`, `fill`), in sRGB: the vibrant palette's color, and for a
    /// background that carries text, that color taken toward the sidebar's black or white.
    public func rgb(_ role: Role, dark: Bool) -> ThemeRGB {
        let swatch = ThemeRGB(hex: dark ? Self.vibrantDark[self] ?? 0xA1A1AA : Self.vibrantLight[self] ?? 0x8E8E93)
        return switch role {
        case .swatch: swatch
        case .fill: dark ? swatch.mixed(toward: ThemeRGB(hex: 0x1C1C1E), 0.55) : swatch.mixed(toward: .white, 0.7)
        }
    }

    /// The vibrant palette on dark glass: OKLCH lightness 0.72 at the most chroma sRGB holds (0.19), yellow and
    /// orange lighter, since a dark veil turns a darker warm hue brown or olive (the group color gallery, 2026-11-07).
    static let vibrantDark: [GroupColor: UInt32] = [
        .grey: 0xA1A1AA, .red: 0xFD7273, .orange: 0xFE843D, .yellow: 0xF5BA14, .green: 0x20C45F,
        .cyan: 0x14BBC2, .blue: 0x62A7FD, .purple: 0xB28BFD, .pink: 0xF46CBF,
    ]

    /// The vibrant palette on light glass: OKLCH lightness 0.66, chroma 0.16.
    static let vibrantLight: [GroupColor: UInt32] = [
        .grey: 0x8E8E93, .red: 0xE36364, .orange: 0xE57431, .yellow: 0xD6A20A, .green: 0x33AC5A,
        .cyan: 0x10A6AD, .blue: 0x4693F1, .purple: 0x9F79E6, .pink: 0xD465A8,
    ]

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
