public import CoreGraphics

/// The shared layout grid in unscaled points. The CSS copy follows interface scale.
/// Hand-maintained against schemas/layout-grid/layout-grid.json by gen-layout-grid.py --check.
/// Menus use MenuMetrics. Comfortable icon boxes apply only to sidebar and Home lists.
public nonisolated struct LayoutGrid: Sendable {
    public init() {}

    public static let base: CGFloat = 4
    public static let halfStep: CGFloat = 2
    public static let iconBox: CGFloat = 16
    public static let iconBoxComfortable: CGFloat = 20
    public static let glyph: CGFloat = 12
    public static let gap: CGFloat = 8
    public static let chevronGap: CGFloat = 4
    public static let hitMin: CGFloat = 24
    public static let row: CGFloat = 28
    public static let pillInset: CGFloat = 2
    public static let pill: CGFloat = 24
    public static let composerText: CGFloat = 44
    public static let stripText: CGFloat = 44
    public static let queueText: CGFloat = 44
    public static let composerBox: CGFloat = 48
    public static let composerRadius: CGFloat = 16
    public static let sidebarHighlightInset: CGFloat = 8
    public static let sidebarLead: CGFloat = 16
    public static let sidebarDepthIndent: CGFloat = 16
    public static let sidebarTrailCenter: CGFloat = 24
    public static let sidebarSecondMarkPitch: CGFloat = 20
    public static let gapBlock: CGFloat = 24
    public static let gapInner: CGFloat = 12
}
