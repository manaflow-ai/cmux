import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Sidebar sizes and fonts, derived only from CmuxNextDesign tokens
/// (`Metrics`, `Typography`). Hierarchy comes from weight and gray level.
enum SidebarStyle {
    static var horizontalInset: CGFloat { SidebarDensityTokens.horizontalInset }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    /// A listed tab's icon, sized to its caption-size title.
    static var tabIconSize: CGFloat { .iconRowSize(forLabelPointSize: subtitleFont.pointSize) }
    /// Height of a placeholder row's bar (about a caption's x-height).
    static var placeholderBarHeight: CGFloat { Metrics.space3 }
    /// Placeholder bar widths, as shares of the title width.
    static let placeholderFractions: [CGFloat] = [0.72, 0.5, 0.62]
    /// Icon frame; the glyph inside is `kindGlyphSize`.
    static var iconBox: CGFloat { Metrics.smallIconSize + Metrics.space2 }
    /// A workspace row's leading glyph: the size an icon takes beside the
    /// row title (cap height and stroke matched to the text).
    static var kindGlyphSize: CGFloat { .iconRowSize(forLabelPointSize: titleFont.pointSize) }
    /// An item's glyph on its `iconBox` well (the list look), clear of the well's edge.
    static var wellGlyphSize: CGFloat { Swift.max(.iconFloor, iconBox - Metrics.space2) }
    static var controlSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var toolbarButtonSize: CGFloat { Metrics.sidebarHeaderHeight }
    static var indicatorSize: CGFloat { Metrics.statusMarkSize }
    /// A workspace row's status mark (the shared indicator, or the agent mark in its place): as
    /// tall as the unread badge beside it (Leo 2026-10-13); both read `Metrics.statusMarkSize`.
    static var statusGlyphSize: CGFloat { badgeHeight }
    static var dotSize: CGFloat { Metrics.space3 }
    /// A window rail button's glyph box and glyph (the Codex rail's 15pt
    /// glyphs on 32pt tiles), and its tile's rounding.
    static var railIconBox: CGFloat { Metrics.iconSize + Metrics.space3 }
    static var railGlyphSize: CGFloat { Metrics.iconSize + 1 }
    static var railTileCornerRadius: CGFloat { Metrics.itemCornerRadius + Metrics.space1 }
    /// The glyph well of a large sidebar-top tile (the tiles arrangement).
    static var favoriteWell: CGFloat { SidebarDensityTokens.rowHeight + Metrics.space1 }
    /// As tall as the status glyph beside it (`Metrics.statusMarkSize`).
    static var badgeHeight: CGFloat { Metrics.statusMarkSize }
    static var searchHeight: CGFloat { Metrics.sidebarRowHeight }
    /// The profile control's circle at compact density (the icon box). The
    /// avatar lives in the row-height square, so its click target scales with
    /// the display density.
    static var avatarDiameter: CGFloat { iconBox }
    static var footerHeight: CGFloat { Metrics.sidebarRowHeightWithSubtitle - Metrics.space2 }
    static var autoscrollZone: CGFloat { Metrics.sidebarRowHeight }
    static var dragThreshold: CGFloat { Metrics.space2 }
    static var overscan: CGFloat { Metrics.sidebarRowHeightWithSubtitle * 10 }

    /// Workspace titles: regular weight, read or unread, selected or not
    /// (Lawrence 2026-10-14: "sidebar text should not be bold by default"),
    /// and every title in the primary text color ("All titles primary"):
    /// unread shows by the badge, selection by the fill.
    static var titleFont: NSFont { Typography.body }
    /// Length of the fade that ends a clipped row title (no ellipsis).
    static var titleFadeWidth: CGFloat { Metrics.space6 }
    static var subtitleFont: NSFont { Typography.caption }
    /// Where a workspace title without a custom icon starts: rows draw no
    /// default icon (WORKSPACE-ROWS-NO-DEFAULT-ICON). Group headers start
    /// their name here too.
    static var titleLeading: CGFloat { horizontalInset }
    /// How far a group member's content moves in past the row's own
    /// leading edge, which already starts right of the line (`groupGutter`).
    static var groupMemberIndent: CGFloat { Metrics.space1 }
    /// The header bar inside its row: 26 of 32 pt, scaled with the row height.
    static func groupHeaderBarHeight(rowHeight: CGFloat) -> CGFloat { rowHeight - 2 * (rowHeight * 0.09).rounded() }
    /// The header's name: medium weight (cx-qno.17: more contrast on the
    /// pastel bar), 14 pt on a 26 pt bar, scaled.
    static func groupHeaderFont(barHeight: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: min(15, max(11, (barHeight * 0.54).rounded())), weight: .medium)
    }
    /// The members' bar: 3 pt at the 32 pt row, scaled; at the members' leading edge.
    static var groupBarWidth: CGFloat { max(2, (Metrics.sidebarRowHeight * 0.1).rounded()) }
    static var groupBarX: CGFloat { (Metrics.sidebarRowHeight * 0.12).rounded() }
    /// A member row starts right of its group's line (cx-q5jw, the Edge
    /// group line): its hover and selection fills never cover the line, so
    /// the line runs unbroken from the header to the last member.
    static var groupGutter: CGFloat { groupBarX + groupBarWidth + Metrics.space1 }
    /// The group header's color dot, on the line's x (cx-25az).
    static var groupDotSize: CGFloat { max(6, (Metrics.sidebarRowHeight * 0.28).rounded()) }
    static var headerFont: NSFont { Typography.header }
    /// The count: tabular digits in the system face (a monospaced face read
    /// boxy and cramped, Leo 2026-10-13), at the shortcut size.
    static var badgeFont: NSFont { Typography.system(.monospacedDigit, size: Typography.shortcut.pointSize, weight: .medium) }
    /// How far an AppKit label cell draws its text inside its frame: a label
    /// sits this much before the edge its text aligns to.
    static var labelCellPadding: CGFloat { Metrics.space1 }
    /// A user-chosen SF Symbol at the title's point size, where symbols match the text beside them.
    static var glyphConfig: NSImage.SymbolConfiguration { .init(pointSize: titleFont.pointSize, weight: .regular) }
    /// A header's disclosure chevron, filling its `Metrics.smallIconSize` box.
    static func chevron(collapsed: Bool) -> NSImage {
        NSImage.icon(collapsed ? .disclosureCollapsed : .disclosureExpanded, size: Metrics.smallIconSize)
    }

    /// A user color from the group palette, shared with tab groups (`GroupColor.markColor`).
    static func color(_ color: GroupColor) -> NSColor {
        color.markColor
    }

}
