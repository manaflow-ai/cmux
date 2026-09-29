/// niri-style column width presets (`switch-preset-column-width`).
public nonisolated enum ColumnWidthPreset: Double, CaseIterable, Sendable {
    case oneThird = 0.3333333333333333
    case half = 0.5
    case twoThirds = 0.6666666666666666
    case full = 1.0

    /// Width of a new column: two-thirds of the viewport (daemon default 0.667).
    public static let defaultWidth: Double = 2.0 / 3.0

    /// Daemon-accepted width range.
    public static let widthRange: ClosedRange<Double> = 0.1...1.0

    /// The next preset strictly wider (forward) or narrower (backward) than
    /// `width`, wrapping around like niri.
    public static func next(after width: Double, forward: Bool = true) -> ColumnWidthPreset {
        let epsilon = 0.01
        let all = allCases
        if forward {
            return all.first { $0.rawValue > width + epsilon } ?? all[0]
        }
        return all.last { $0.rawValue < width - epsilon } ?? all[all.count - 1]
    }
}

/// Daemon-accepted split ratio range.
public nonisolated enum SplitRatio {
    public static let range: ClosedRange<Double> = 0.05...0.95
}
