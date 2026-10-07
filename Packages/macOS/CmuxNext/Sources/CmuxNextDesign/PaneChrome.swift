public import CoreGraphics

/// Border drawn around every pane (`layout.paneBorder` in cmux.json).
public nonisolated enum PaneBorderStyle: String, Sendable, CaseIterable, Codable {
    /// A one-device-pixel hairline in `Palette.paneBorder`.
    case subtle
    /// No border; with zero padding panes are edge to edge.
    case none
}

/// How panes are told apart (`layout.paneSeparation` in cmux.json, R93).
/// `layout.panePadding`, `layout.paneCornerRadius` and the border keys
/// refine it; `appearance.borders` = none still removes every line.
public nonisolated enum PaneSeparation: String, Sendable, CaseIterable, Codable {
    /// Edge to edge with nothing drawn: no border and no divider line at
    /// rest, on hover or while dragging. Resizing still works through the
    /// invisible hit area and the resize cursor.
    case none
    /// Edge to edge with one line between neighboring panes.
    case dividers
    /// Padded panes, each outlined by a hairline (the default).
    case borders
    /// Padded rounded panes with gaps and no outline.
    case cards

    /// What `overrides` resolve to: an explicit separation, else the legacy
    /// `layout.paneBorder` (none) and padding (0 means edge to edge).
    public static func resolve(_ overrides: PaneChromeOverrides) -> PaneSeparation {
        if let separation = overrides.separation { return separation }
        guard overrides.border == PaneBorderStyle.none else { return .borders }
        return overrides.padding == 0 ? .dividers : .cards
    }

    /// The pane padding this separation implies; nil keeps the density's.
    public var impliedPadding: CGFloat? {
        switch self {
        case .none, .dividers: 0
        case .borders, .cards: nil
        }
    }

    /// Each pane draws its own hairline outline.
    public var drawsPaneBorder: Bool { self == .borders }
    /// A split divider may draw its line at rest.
    public var drawsIdleDivider: Bool { self == .dividers }
    /// A divider or column edge shows its line on hover and while dragged.
    public var drawsDividerFeedback: Bool { self != .none }
}

/// User overrides for pane chrome (`layout.panePadding`,
/// `layout.paneCornerRadius`, `layout.paneBorder`, `layout.paneBorderColor`,
/// `layout.paneBorderWidth` and `layout.paneSeparation`). Nil fields follow the defaults in
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
    /// `layout.paneSeparation`; nil derives it from `border` and `padding`
    /// (`PaneSeparation.resolve`).
    public var separation: PaneSeparation?

    public init(padding: CGFloat? = nil, cornerRadius: CGFloat? = nil, border: PaneBorderStyle? = nil,
                borderColor: ThemeRGB? = nil, borderWidth: CGFloat? = nil, separation: PaneSeparation? = nil) {
        self.separation = separation
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
