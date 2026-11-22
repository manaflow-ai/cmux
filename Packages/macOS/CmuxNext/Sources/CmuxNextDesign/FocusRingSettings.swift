public import CoreGraphics

/// How the focused pane is marked (`focusRing.style` in cmux.json).
public nonisolated enum FocusRingStyle: String, Hashable, Sendable, CaseIterable {
    /// A stroke on the pane's rounded content rect.
    case ring
    /// A soft glow inside the content rect's edge.
    case glow
    case none
}

/// How far the theme-colored ring stands out (`focusRing.contrast`).
public nonisolated enum FocusRingContrast: String, Hashable, Sendable, CaseIterable {
    case subtle
    case standard
    case strong

    /// The ring's share of the Ghostty foreground (it replaces the focus
    /// token's own alpha). Subtle is 20%, about 2.5 times a pane border, so
    /// the focused pane stays findable; standard is the previous 55%.
    public var ringAlpha: CGFloat {
        switch self {
        case .subtle: 0.20
        case .standard: 0.55
        case .strong: 0.85
        }
    }
}

/// `focusRing.*` in cmux.json. Drawn in the layout's overlay plane, so it
/// never changes a pane frame or inset (plans/cmux-next/focus.md, ring).
public nonisolated struct FocusRingSettings: Hashable, Sendable {
    public var enabled = true
    public var style: FocusRingStyle = .ring
    /// nil takes the Ghostty theme's focus color (`Palette.focusRing`).
    public var color: ThemeRGB?
    /// Strength of the theme color; ignored when `color` is set.
    public var contrast: FocusRingContrast = .subtle
    public var width: CGFloat = 1
    /// nil follows the pane corner radius (`layout.paneCornerRadius`).
    public var cornerRadius: CGFloat?
    /// Also mark the only pane on screen.
    public var showsForSinglePane = false

    public init() {}

    public static let widthRange: ClosedRange<CGFloat> = 0.5...8
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...24

    /// Alpha for the theme focus color: the Debug Settings override, else `contrast`.
    public func themeRingAlpha(override: CGFloat?) -> CGFloat { override ?? contrast.ringAlpha }

    /// The style that draws: `none` while disabled.
    public var effectiveStyle: FocusRingStyle { enabled ? style : .none }
}

extension FocusRingSettings {
    /// The pane ring color: `color` when set, else the theme focus color
    /// (the Ghostty foreground, no accent hue) at `themeRingAlpha`. The one
    /// rule the overlay draws and the tests check.
    public func ringColor(in tokens: ThemeTokens, override: CGFloat?) -> ThemeRGB {
        color ?? tokens.focusRing.withAlpha(Double(themeRingAlpha(override: override)))
    }
}
