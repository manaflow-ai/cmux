public import CoreGraphics
public import CmuxNextDesign

/// Every size the strip uses, derived from the CmuxNextDesign density tokens
/// (`Metrics`, 2 pt grid). Plain data so layout math is testable with fixed
/// numbers; `standard` reads the tokens for the current density.
public struct TabStripMetrics: Equatable, Sendable {
    /// Widest an unpinned tab gets (the standard width).
    public var maxTabWidth: CGFloat
    /// Narrowest an inactive tab gets before the strip starts to scroll.
    public var minInactiveTabWidth: CGFloat
    /// The selected tab never gets narrower than this (nor than the inactive
    /// minimum), so it keeps room for its icon, title and close button.
    public var minActiveTabWidth: CGFloat
    /// `tabs.overflow`: with `.scroll` both minimums are `scrollTabMinWidth`.
    public var overflow: TabOverflow
    public var pinnedTabWidth: CGFloat
    /// Chrome's strip geometry (design-tokens.json `motion.tabStrip`, at the UI scale): open and
    /// close widths, the minimum widths above, the reorder threshold, closing mode.
    public var chrome: MotionTabStrip
    /// Width of every unpinned tab in `.compact` style.
    public var compactTabWidth: CGFloat
    /// Extra space between the last pinned tab and the first unpinned tab.
    public var pinnedGroupGap: CGFloat

    /// Contents width (the tab less both content insets) from which a
    /// hovered inactive tab shows its x. Chromium's
    /// `Tab::kMinimumContentsWidthForCloseButtons`, as Helium sets it (56 DIP; Chromium 68).
    public var closeMinContentsWidth: CGFloat
    /// Narrowest title fragment worth showing after the icon; below it the
    /// icon centers instead (Chromium shows any positive width, which
    /// with a fade is a smudge of a few points).
    public var titleMinVisibleWidth: CGFloat

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
    /// Length of the fade on a scrolled edge.
    public var scrollFadeWidth: CGFloat
    /// Inset of the tab background from the tab frame, so neighbors read as separate.
    public var tabBackgroundInset: CGFloat
    /// Vertical distance outside the strip that hands a dragged tab to the drag session.
    public var tearOffDistance: CGFloat

    /// Every pill's corner radius (`Metrics.tabCornerRadius`): concentric with the card
    /// corner the strip sits in; the strip's + and a tab's hover card share it.
    public var cornerRadius: CGFloat
    /// Corner of the close button's hover and pressed fill: Helium's rounded
    /// rect (`TabCloseButton` `kCornerRadius`, 4), not Chrome's circle.
    public var closeCornerRadius: CGFloat

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
    /// Whether a line separates tabs (`tabs.separators`), its height and its strength.
    public var showsSeparators: Bool
    public var separatorHeight: CGFloat
    public var separatorOpacity: CGFloat
    /// A group chip's icon: the tab icon size, inset inside the pill's height.
    public var groupChipIconSize: CGFloat { max(0, min(iconSize, groupChipHeight - 2 * Metrics.space1)) }
    /// Between a group chip's icon and its name or count.
    public var groupChipIconSpacing: CGFloat { groupChipCountSpacing }

    /// Narrowest slot that holds the favicon and the close button whole, side by side (Lawrence
    /// 2026-10-20): both pill insets, the leading inset, the favicon, the favicon-to-x gap, the x and
    /// its trailing inset. The x's click target is the drawn button plus 2 pt a side
    /// (`TabStripView.isInCloseButton`), Apple's 20 x 20 pt macOS minimum, and it stays clear of the
    /// favicon and inside the pill. 50 comfortable (2 + 8 + 16 + 4 + 16 + 4), 48 compact (14 pt
    /// favicon), 46 under Compact tabs (6 pt leading inset): the default minimum tab width.
    public var faviconCloseWidth: CGFloat {
        2 * tabBackgroundInset + contentLeadingInset + iconSize + titleCloseSpacing + closeButtonSize + contentTrailingInset
    }

    /// Vertical inset of tabs inside the strip.
    public var stripVerticalPadding: CGFloat { max(0, (stripHeight - tabHeight) / 2) }

    /// Space above the strip that counts toward the gap above its tabs (the
    /// pane padding): tabs sit with equal gaps above (from the pane cell's
    /// top) and below (to the content border), `PaneChromeMetrics`.
    public var stripTopOutset: CGFloat = 0

    /// The tabs' top in a strip `height` points tall, on `scale`'s pixel grid.
    public func tabTop(stripHeight height: CGFloat, scale: CGFloat) -> CGFloat {
        PaneChromeMetrics(stripHeight: height, tabHeight: min(tabHeight, height), panePadding: stripTopOutset).pillTop(scale: scale)
    }

    /// A tab pill (its rounded background) inside a slot `width` wide: the
    /// gap to the next pill is all on the trailing side, so the first pill
    /// starts on the strip's leading edge.
    public func pillFrame(slotWidth width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: max(0, width - 2 * tabBackgroundInset), height: height)
    }

    /// Reads the design tokens for the current density.
    public init() {
        maxTabWidth = Metrics.tabMaxWidth
        chrome = MotionTabStrip(comfortable: Metrics.density == .comfortable).scaled(by: Metrics.scale(1))
        // Chrome crowding: every tab shrinks evenly to the active minimum, then the inactive ones to theirs.
        // The minimums and the pinned width are settings (defaults: the shared tokens); min <= max.
        pinnedTabWidth = Metrics.tabPinnedWidth
        compactTabWidth = TabTunables.compactTabWidth.value
        pinnedGroupGap = TabTunables.pinnedGroupGap.value
        contentLeadingInset = Metrics.tabContentLeadingInset
        contentTrailingInset = TabTunables.contentTrailingInset.value
        iconSize = Metrics.iconSize
        closeButtonSize = TabTunables.closeButtonSize.value
        closeGlyphSize = TabTunables.closeGlyphSize.value
        iconTitleSpacing = TabTunables.iconTitleSpacing.value
        titleCloseSpacing = TabTunables.titleCloseSpacing.value
        titleFadeWidth = TabTunables.titleFadeWidth.value
        badgeSize = TabTunables.badgeSize.value
        // Never narrower than the active tab's icon and close button need (`faviconCloseWidth`; self is
        // not usable before every property is set), never wider than the max; the inactive minimum never
        // passes the active one.
        let activeFloor = 2 * Metrics.tabBackgroundInset + contentLeadingInset + iconSize + titleCloseSpacing + closeButtonSize
            + contentTrailingInset
        overflow = DesignSettings.shared.tabOverflow
        switch overflow {
        case .shrink:
            // A larger inactive minimum (a user's) raises the active one, never the other way round.
            minInactiveTabWidth = min(Metrics.tabMinInactiveWidth, maxTabWidth)
            minActiveTabWidth = min(max(Metrics.tabMinActiveWidth, activeFloor, minInactiveTabWidth), maxTabWidth)
        case .scroll:
            // Scrolling tabs: every unpinned tab stays this wide, then the strip scrolls.
            minActiveTabWidth = min(max(TabTunables.scrollTabMinWidth.value, activeFloor), maxTabWidth)
            minInactiveTabWidth = minActiveTabWidth
        }
        closeMinContentsWidth = TabTunables.closeMinContentsWidth.value
        titleMinVisibleWidth = TabTunables.titleMinVisibleWidth.value
        stripHeight = Metrics.tabStripHeight
        tabHeight = Metrics.tabHeight
        // The first and last pills keep the gap above them to the strip's ends (the chrome line).
        stripHorizontalPadding = Metrics.paneChromeInset
        stripTopOutset = Metrics.stripTopOutset
        newTabButtonWidth = Metrics.controlHeight
        scrollFadeWidth = TabTunables.scrollFadeWidth.value
        tabBackgroundInset = Metrics.tabBackgroundInset
        tearOffDistance = TabTunables.tearOffDistance.value
        cornerRadius = Metrics.tabCornerRadius
        closeCornerRadius = Metrics.space2
        groupChipOuterInset = Metrics.space1
        groupChipPadding = TabTunables.groupChipPadding.value
        groupChipHeight = max(Metrics.space6, Metrics.tabHeight - 2 * Metrics.space2)
        groupChipDotSize = Metrics.space5 - Metrics.space1
        groupChipMaxNameWidth = (Metrics.tabMaxWidth / 2).rounded()
        groupChipCountSpacing = Metrics.space2
        groupUnderlineHeight = TabTunables.groupUnderlineHeight.value
        showsSeparators = TabTunables.separators.value
        separatorHeight = TabTunables.separatorHeight.value
        separatorOpacity = TabTunables.separatorOpacity.value
    }

    /// Token-derived metrics for the current density.
    public static var standard: TabStripMetrics { TabStripMetrics() }
}
