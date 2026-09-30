public import CoreGraphics

/// Border drawn around every pane (`layout.paneBorder` in cmux.json).
public nonisolated enum PaneBorderStyle: String, Sendable, CaseIterable, Codable {
    /// A one-device-pixel hairline in `Palette.paneBorder`.
    case subtle
    /// No border; with zero padding panes are edge to edge.
    case none
}

/// User overrides for pane chrome (`layout.panePadding`,
/// `layout.paneCornerRadius`, `layout.paneBorder`). Nil fields follow the
/// density defaults in `Metrics`.
public nonisolated struct PaneChromeOverrides: Hashable, Sendable {
    public var padding: CGFloat?
    public var cornerRadius: CGFloat?
    public var border: PaneBorderStyle?

    public init(padding: CGFloat? = nil, cornerRadius: CGFloat? = nil, border: PaneBorderStyle? = nil) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.border = border
    }

    public static let paddingRange: ClosedRange<CGFloat> = 0...16
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...20

    /// These overrides with padding and radius clamped to their ranges.
    public var clamped: PaneChromeOverrides {
        PaneChromeOverrides(
            padding: padding.map { min(max($0, Self.paddingRange.lowerBound), Self.paddingRange.upperBound) },
            cornerRadius: cornerRadius.map { min(max($0, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound) },
            border: border
        )
    }
}
