import CoreGraphics

/// Geometry shared by the SwiftUI Vault rows and the AppKit table that hosts
/// them.
///
/// `SessionRow`, `PopoverRow`, the section header and its drag preview, and
/// `SessionIndexTableRowHeightCalculator` all read these values, so the hosted
/// row layout and the precomputed `NSTableView` row heights cannot drift
/// apart: a glyph or padding change lands in exactly one place.
enum SessionIndexRowMetrics {
    /// Agent glyph size in session rows. The glyph draws bare, with no tile
    /// behind it, so rows and section headers share one transparent
    /// icon treatment.
    static let agentIconSize: CGFloat = 12
    /// Glyph size for section headers and popover headers: the sidebar's
    /// shared content icon column, which the grouping pills and the search
    /// field's magnifier also sit on.
    static let sectionIconSize: CGFloat = RightSidebarChromeMetrics.contentIconFrameSize
    /// Spacing between the glyph and the title on a row's primary line.
    static let primaryLineSpacing: CGFloat = 6
    /// Leading inset that starts the detail subtitle on the title's column.
    static let detailLeadingInset: CGFloat = agentIconSize + primaryLineSpacing
    /// Vertical spacing between a row's primary line and its detail subtitle.
    static let detailLineSpacing: CGFloat = 1
    /// Vertical padding above and below each session row.
    static let verticalPadding: CGFloat = 4
}
