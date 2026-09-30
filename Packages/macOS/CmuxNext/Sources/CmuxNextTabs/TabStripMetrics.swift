public import CoreGraphics
import CmuxNextDesign

/// Every size the strip uses, derived from the CmuxNextDesign density tokens
/// (`Metrics`, 2 pt grid). Plain data so layout math is testable with fixed
/// numbers; `standard` reads the tokens for the current density.
public struct TabStripMetrics: Equatable, Sendable {
    /// Widest an unpinned tab gets (Chrome's standard width).
    public var maxTabWidth: CGFloat
    /// Narrowest an inactive tab gets before the strip starts to scroll.
    public var minInactiveTabWidth: CGFloat
    /// The selected tab never gets narrower than this, so it keeps room for
    /// its icon and close button while the others shrink to icons.
    public var minActiveTabWidth: CGFloat
    public var pinnedTabWidth: CGFloat
    /// Width of every unpinned tab in `.compact` style.
    public var compactTabWidth: CGFloat
    /// Extra space between the last pinned tab and the first unpinned tab.
    public var pinnedGroupGap: CGFloat

    /// Hovered inactive tabs show a close button only when at least this wide.
    public var hoverCloseMinWidth: CGFloat
    /// Below this width the title is hidden entirely.
    public var titleMinWidth: CGFloat

    public var contentLeadingInset: CGFloat
    public var contentTrailingInset: CGFloat
    public var iconSize: CGFloat
    public var closeButtonSize: CGFloat
    /// Side of the close glyph (the X) inside the close button.
    public var closeGlyphSize: CGFloat
    public var iconTitleSpacing: CGFloat
    public var titleCloseSpacing: CGFloat
    /// Length of the gradient that fades a clipped title.
    public var titleFadeWidth: CGFloat
    /// Diameter of the unread / status dot.
    public var badgeSize: CGFloat

    public var stripHeight: CGFloat
    public var tabHeight: CGFloat
    /// Horizontal inset of the strip content from its bounds.
    public var stripHorizontalPadding: CGFloat
    public var newTabButtonWidth: CGFloat
    /// Side of each square button in the trailing group.
    public var trailingButtonSize: CGFloat
    public var trailingButtonSpacing: CGFloat
    /// Space between the tabs viewport and the trailing group.
    public var trailingGroupGap: CGFloat
    /// Glyph box and symbol point size of a trailing button.
    public var trailingIconSize: CGFloat
    public var trailingIconPointSize: CGFloat
    /// Length of the fade on a scrolled edge.
    public var scrollFadeWidth: CGFloat
    /// Inset of the tab background from the tab frame, so neighbors read as separate.
    public var tabBackgroundInset: CGFloat
    /// Height of the 1 px separator between inactive tabs.
    public var separatorHeight: CGFloat
    /// Vertical distance outside the strip that hands a dragged tab to the drag session.
    public var tearOffDistance: CGFloat

    public var cornerRadius: CGFloat

    // MARK: Groups

    /// Space between a chip's pill and its slot edges.
    public var groupChipOuterInset: CGFloat
    /// Horizontal padding inside the pill.
    public var groupChipPadding: CGFloat
    public var groupChipHeight: CGFloat
    /// Diameter of the chip of an unnamed, expanded group.
    public var groupChipDotSize: CGFloat
    /// Longer names are faded out.
    public var groupChipMaxNameWidth: CGFloat
    /// Between the name and the collapsed member count.
    public var groupChipCountSpacing: CGFloat
    public var groupUnderlineHeight: CGFloat

    /// Vertical inset of tabs inside the strip.
    public var stripVerticalPadding: CGFloat { max(0, (stripHeight - tabHeight) / 2) }

    /// Reads the design tokens for the current density.
    public init() {
        maxTabWidth = Metrics.tabMaxWidth
        minInactiveTabWidth = Metrics.tabMinWidth
        pinnedTabWidth = Metrics.tabMinWidth
        compactTabWidth = (Metrics.tabMaxWidth * 3 / 4).rounded()
        pinnedGroupGap = Metrics.space2
        contentLeadingInset = Metrics.space4
        contentTrailingInset = Metrics.space2
        iconSize = Metrics.iconSize
        closeButtonSize = Metrics.space6
        closeGlyphSize = Metrics.space4 - Metrics.space1 / 2
        iconTitleSpacing = Metrics.space3
        titleCloseSpacing = Metrics.space2
        titleFadeWidth = Metrics.space6 + Metrics.space2
        badgeSize = Metrics.space3
        minActiveTabWidth = contentLeadingInset + iconSize + titleCloseSpacing + closeButtonSize + contentTrailingInset
        hoverCloseMinWidth = Metrics.tabMinWidth
        titleMinWidth = Metrics.tabMinWidth * 2
        stripHeight = Metrics.tabStripHeight
        tabHeight = Metrics.tabHeight
        stripHorizontalPadding = max(0, (Metrics.tabStripHeight - Metrics.tabHeight) / 2)
        newTabButtonWidth = Metrics.tabHeight
        trailingButtonSize = Metrics.tabHeight - Metrics.space2
        trailingButtonSpacing = Metrics.space1
        trailingGroupGap = Metrics.space2
        trailingIconSize = Metrics.iconSize
        trailingIconPointSize = Metrics.smallIconSize
        scrollFadeWidth = Metrics.space6 + Metrics.space4
        tabBackgroundInset = Metrics.space1 / 2
        separatorHeight = Metrics.tabHeight / 2
        tearOffDistance = Metrics.space6 + Metrics.space4
        cornerRadius = Metrics.itemCornerRadius
        groupChipOuterInset = Metrics.space1
        groupChipPadding = Metrics.space3
        groupChipHeight = max(Metrics.space6, Metrics.tabHeight - 2 * Metrics.space2)
        groupChipDotSize = Metrics.space5 - Metrics.space1
        groupChipMaxNameWidth = (Metrics.tabMaxWidth / 2).rounded()
        groupChipCountSpacing = Metrics.space2
        groupUnderlineHeight = Metrics.space1
    }

    /// Token-derived metrics for the current density.
    public static var standard: TabStripMetrics { TabStripMetrics() }
}
