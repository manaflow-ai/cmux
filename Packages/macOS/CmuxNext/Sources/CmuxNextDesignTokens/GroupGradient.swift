/// The gradient a sidebar under the ``GroupPalette/gradient`` palette steps its groups through (`sidebar.groupGradient`).
/// Each is two or three OKLCH stops, blended in OKLCH so a mix keeps its chroma instead of going brown (Leo
/// 2026-11-07: "you want to make sure you do the thing where they don't become brown ... It maintains its vibrance").
public nonisolated enum GroupGradient: String, Hashable, Sendable, CaseIterable {
    /// Pink, orange, then yellow. The default.
    case sunset
    /// Purple, cyan, then green.
    case aurora
    /// Blue, teal, then sea green.
    case lagoon
    /// Purple into orange.
    case twoTone

    /// The stops, top of the sidebar first: OKLCH lightness (0...1), chroma and hue in degrees.
    public var stops: [(lightness: Double, chroma: Double, hue: Double)] {
        switch self {
        case .sunset: [(0.70, 0.19, 350), (0.72, 0.18, 40), (0.84, 0.16, 85)]
        case .aurora: [(0.72, 0.17, 300), (0.74, 0.14, 200), (0.78, 0.17, 150)]
        case .lagoon: [(0.70, 0.16, 265), (0.76, 0.13, 205), (0.80, 0.15, 165)]
        case .twoTone: [(0.70, 0.18, 300), (0.76, 0.17, 50)]
        }
    }
}
