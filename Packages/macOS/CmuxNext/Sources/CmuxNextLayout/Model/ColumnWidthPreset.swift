/// niri-style column width presets (`switch-preset-column-width`).
public nonisolated enum ColumnWidthPreset: Double, CaseIterable, Sendable {
    case oneThird = 0.3333333333333333
    case half = 0.5
    case twoThirds = 0.6666666666666666
    case full = 1.0

    /// Built-in width of a new column: half the viewport, niri's
    /// `default-column-width { proportion 0.5; }`. cmux.json
    /// `layout.defaultColumnWidth` overrides it (`LayoutModel.defaultColumnWidth`).
    /// The cmux-tui default for a `new-pane-right` without a width is still 2/3,
    /// so the app always sends a width.
    public static let defaultWidth: Double = 0.5

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
