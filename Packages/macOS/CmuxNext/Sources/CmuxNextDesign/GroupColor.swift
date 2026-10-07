public import AppKit

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

    /// The color a new space or browser profile gets: the first color not in
    /// `used`, never blue (the no-blue rule covers what the app picks by
    /// itself) or grey (no color). Nil when every such color is in use.
    public static func automatic(used: Set<String>) -> GroupColor? {
        allCases.first { $0 != .grey && $0 != .blue && !used.contains($0.rawValue) }
    }

    /// The color itself: swatches, group underlines, sidebar rails.
    public var swatch: NSColor { tint(saturation: (0.42, 0.40), brightness: (0.64, 0.68)) }
    /// Chip and label backgrounds that carry text.
    public var fill: NSColor { tint(saturation: (0.30, 0.34), brightness: (0.86, 0.40)) }
    /// A very light wash behind grouped content.
    public var wash: NSColor { swatch.withAlphaComponent(0.09) }

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

    private func tint(saturation: (light: CGFloat, dark: CGFloat), brightness: (light: CGFloat, dark: CGFloat)) -> NSColor {
        let (hue, chroma) = hueAndChroma
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(
                calibratedHue: hue / 360,
                saturation: (dark ? saturation.dark : saturation.light) * chroma,
                brightness: dark ? brightness.dark : brightness.light,
                alpha: 1
            )
        }
    }

    /// Fills `layer` as a round swatch of this color, with an optional ring
    /// for the chosen state. Resolves colors against `appearance`.
    public func renderSwatch(into layer: CALayer, ringColor: NSColor?, ringWidth: CGFloat, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = swatch.cgColor
            layer.borderColor = ringColor?.cgColor
        }
        layer.borderWidth = ringColor == nil ? 0 : ringWidth
        layer.cornerRadius = min(layer.bounds.width, layer.bounds.height) / 2
    }
}
