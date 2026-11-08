public import CoreGraphics

extension SidebarRowTokens {
    /// The workspace hover card at this density (docs/cmux-next/derived-sizing.md): the rows' title and detail
    /// text, the rows' inset plus a `space1` around the content, an icon a step above the detail text, widths in
    /// titles (so a larger text size widens the card with its text), tab rows one row tall (two-line rows add the
    /// detail text) and the disclosure a row plus `space1`. At the compact app density, compact and default text:
    /// 8 pt padding, 13 pt icons, 12/10.5 pt text, 280 pt wide, 24/34 pt tab rows and a 26 pt disclosure.
    /// Sized from ``band``, so at Expanded the card is Comfortable's, like the pinned rows that open it.
    public var hoverCard: SidebarHoverCardMetrics { band.ownHoverCard }

    /// The hover card from these tokens themselves.
    private var ownHoverCard: SidebarHoverCardMetrics {
        typealias M = SidebarHoverCardMetrics
        let padding = horizontalInset + base.space1
        func width(_ titles: CGFloat) -> CGFloat { ((titleSize * titles / 2).rounded() * 2) + 2 * padding }
        return SidebarHoverCardMetrics(
            padding: padding, iconSide: (captionSize + base.space1).rounded(), titleSize: titleSize, captionSize: captionSize,
            width: width(M.textColumnInTitles), maxWidth: width(M.maxTextColumnInTitles), minWidth: width(M.minTextColumnInTitles),
            logWidth: width(M.logTextColumnInTitles), sidebarReach: titleSize * M.sidebarReachInTitles,
            timelineMaxHeight: rowHeight * M.timelineRows, logMaxHeight: rowHeight * M.logRows,
            tabRowHeight: rowHeight, tabRowHeightTwoLines: rowHeight + captionSize.rounded(.down),
            disclosureHeight: rowHeight + base.space1)
    }
}
