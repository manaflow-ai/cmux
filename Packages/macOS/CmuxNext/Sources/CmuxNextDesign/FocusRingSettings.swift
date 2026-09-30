public import CoreGraphics

/// How the focused pane is marked (`focusRing.style` in cmux.json).
public nonisolated enum FocusRingStyle: String, Hashable, Sendable, CaseIterable {
    /// A stroke on the pane's rounded content rect.
    case ring
    /// A soft glow inside the content rect's edge.
    case glow
    case none
}

/// `focusRing.*` in cmux.json. Drawn in the layout's overlay plane, so it
/// never changes a pane frame or inset (plans/cmux-next/focus.md, ring).
public nonisolated struct FocusRingSettings: Hashable, Sendable {
    public var enabled = true
    public var style: FocusRingStyle = .ring
    /// nil takes the Ghostty theme's focus color (`Palette.focusRing`).
    public var color: ThemeRGB?
    public var width: CGFloat = 1
    /// nil follows the pane corner radius (`layout.paneCornerRadius`).
    public var cornerRadius: CGFloat?
    /// Also mark the only pane on screen.
    public var showsForSinglePane = false

    public init() {}

    public static let widthRange: ClosedRange<CGFloat> = 0.5...8
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...24

    /// The style that draws: `none` while disabled.
    public var effectiveStyle: FocusRingStyle { enabled ? style : .none }
}
