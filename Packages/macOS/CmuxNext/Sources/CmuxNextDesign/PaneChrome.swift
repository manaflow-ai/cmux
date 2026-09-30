public import CoreGraphics

/// Border drawn around every pane (`layout.paneBorder` in cmux.json).
public nonisolated enum PaneBorderStyle: String, Sendable, CaseIterable, Codable {
    /// A one-device-pixel hairline in `Palette.paneBorder`.
    case subtle
    /// No border; with zero padding panes are edge to edge.
    case none
}

/// User overrides for pane chrome (`layout.panePadding`,
/// `layout.paneCornerRadius`, `layout.paneBorder`, `layout.paneBorderColor`,
/// and `layout.paneBorderWidth`). Nil fields follow the defaults in
/// `Metrics` (density padding and radius, a subtle one-pixel border in the
/// Ghostty theme's border color). The focus ring is `focusRing.*`.
public nonisolated struct PaneChromeOverrides: Hashable, Sendable {
    public var padding: CGFloat?
    public var cornerRadius: CGFloat?
    public var border: PaneBorderStyle?
    /// Border color; nil derives it from the Ghostty theme.
    public var borderColor: ThemeRGB?
    /// Border width in points; nil is one device pixel.
    public var borderWidth: CGFloat?

    public init(padding: CGFloat? = nil, cornerRadius: CGFloat? = nil, border: PaneBorderStyle? = nil,
                borderColor: ThemeRGB? = nil, borderWidth: CGFloat? = nil) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.border = border
        self.borderColor = borderColor
        self.borderWidth = borderWidth
    }

    public static let paddingRange: ClosedRange<CGFloat> = 0...16
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...20
    public static let borderWidthRange: ClosedRange<CGFloat> = 0.5...4

    /// These overrides with padding, radius and width clamped to their ranges.
    public var clamped: PaneChromeOverrides {
        var result = self
        result.padding = padding.map { Self.clamp($0, Self.paddingRange) }
        result.cornerRadius = cornerRadius.map { Self.clamp($0, Self.cornerRadiusRange) }
        result.borderWidth = borderWidth.map { Self.clamp($0, Self.borderWidthRange) }
        return result
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
