public import CoreGraphics

/// Geometry constants for the right-sidebar chrome bars and their controls
/// (bar heights, paddings, control sizes, corner radii).
///
/// A pure constant table with no instance dimension. Kept as a caseless
/// namespace for the byte-identical lift; value-type redesign deferred.
// lint:allow namespace-type — faithful lift of the pre-existing app-target right-sidebar chrome-metric constant table; value-type redesign is call-site-changing and deferred to a separate commit.
public enum RightSidebarChromeMetrics {
    /// Height of the right-sidebar primary titlebar.
    public static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    /// Height of the right-sidebar secondary bar.
    public static let secondaryBarHeight: CGFloat = WindowChromeMetrics.secondaryTitlebarHeight
    /// Horizontal padding inside a chrome bar.
    public static let barHorizontalPadding: CGFloat = 8
    /// Vertical padding inside a chrome bar.
    public static let barVerticalPadding: CGFloat = 4
    /// Height of an inline control, after vertical padding.
    public static let controlHeight: CGFloat = secondaryBarHeight - (barVerticalPadding * 2)
    /// Horizontal padding inside an inline control.
    public static let controlHorizontalPadding: CGFloat = 8
    /// Corner radius of an inline control.
    public static let controlCornerRadius: CGFloat = 5
    /// Edge length of a header control button.
    public static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    /// Point size of a header control glyph.
    public static let headerIconSize: CGFloat = 10
    /// Edge length of a header control glyph's frame.
    public static let headerIconFrameSize: CGFloat = headerIconSize
    /// Spacing between header control buttons.
    public static let headerControlSpacing: CGFloat = 4
    /// Corner radius of a header control button.
    public static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    /// Center-alignment adjustment applied to header controls.
    public static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}
