import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Sidebar sizes and fonts, derived only from CmuxNextDesign tokens
/// (`Metrics`, `Typography`). Hierarchy comes from weight and gray level.
enum SidebarStyle {
    static var horizontalInset: CGFloat { SidebarDensityTokens.horizontalInset }
    /// Every row highlight ends on the same outer inset.
    static var rowTrailingTrim: CGFloat { rowEdgeGap - horizontalInset }
    /// Leo 2026-10-27: "one or two pixels, 1.5"; content columns do not change the fill edge.
    static let rowEdgeGap: CGFloat = 1.5
    static var rowCornerRadius: CGFloat { SidebarDensityTokens.rowCornerRadius }
    /// Height of a placeholder row's bar (about a caption's x-height).
    static var placeholderBarHeight: CGFloat { Metrics.space3 }
    /// Placeholder bar widths, as shares of the title width.
    static let placeholderFractions: [CGFloat] = [0.72, 0.5, 0.62]
    /// Icon frame; the glyph inside is `kindGlyphSize`.
    static var iconBox: CGFloat { leadingGlyphSide + Metrics.space2 }
    /// A leading glyph drawn at a fixed side (a pin, a header's leading icon): the small icon size plus the
    /// `sidebar.textSize` step, so it grows with the text beside it. Trailing marks keep `Metrics.smallIconSize`.
    static var leadingGlyphSide: CGFloat { Metrics.smallIconSize + SidebarDensityTokens.textSize.glyphStep }
    /// A sidebar text style at the `sidebar.textSize` step (Lawrence msg 17752): `base`'s size plus
    /// ``SidebarTextSize/textStep``, at `weight`. The default size returns `base` itself.
    ///
    /// Row layout reads titles and details on every pass, so the font comes from `Typography.system`, which
    /// keeps one font per (design, size, weight) for the process (`CheckedFont`): no font object is made per row
    /// layout, and no sidebar cache is needed (a590's review). A text size or type scale change asks for a new size.
    static func sized(_ base: NSFont, weight: NSFont.Weight) -> NSFont {
        let step = SidebarDensityTokens.textSize.textStep
        guard step != 0 else { return base }
        return Typography.system(.default, size: base.pointSize + step, weight: weight)
    }
    /// The one leading icon column (Leo 2026-10-28: "the alignment"): in a row whose leading slot starts at `leading`,
    /// every leading glyph (a band row's, a pinned row's pin, a workspace row's icon) centers its ink here, one
    /// `iconBox` wide, so glyphs of different shapes and margins share one center x at every density.
    static func iconColumnCenterX(leading: CGFloat) -> CGFloat { leading + iconColumnBox / 2 }
    /// The leading icon column's box (grid.md 3: 16 compact, 20 comfortable, wider when the text size grows the
    /// glyph). Leading icon frames take this box and draw their glyph, at its own `iconBox` size, centered in it,
    /// so the text column is one 8 pt gap after the frame at both densities.
    static var iconColumnBox: CGFloat { columns(rowWidth: 0).iconBox }
    /// A workspace row's leading glyph: the size an icon takes beside the
    /// row title (cap height and stroke matched to the text).
    static var kindGlyphSize: CGFloat { .iconRowSize(forLabelPointSize: titleFont.pointSize) }
    /// Reserve the icon column only when a visible icon precedes the title.
    static func titleTextX(leading: CGFloat, iconSide: CGFloat, swatch: Bool = false) -> CGFloat {
        columns(rowWidth: 0, leadingOffset: leading - titleLeading).text(hasLeadingMark: iconSide > 0)
    }
    /// Workspace title geometry shared by realized rows and virtualized parents of tab rows. A left-rail row with no
    /// symbol, emoji or favicon keeps the swatch's slot (#25705), so its title sits where the dot style draws it.
    static func workspaceTitleX(icon: WorkspaceIcon?, treeDepth: Int, reservesColorRail: Bool = false) -> CGFloat {
        columns(rowWidth: 0, depth: treeDepth).text(hasLeadingMark: icon != nil || reservesColorRail) - WorkspaceRowView.labelInset
    }
    static func titleXAfterLeadingMark(_ x: CGFloat) -> CGFloat {
        x + WorkspaceRowView.labelInset + indicatorSize + Metrics.space1
    }
    static func leadingTextX(leading: CGFloat) -> CGFloat { columns(rowWidth: 0, leadingOffset: leading - titleLeading).text }
    /// An item's glyph on its `iconBox` well (the list look), clear of the well's edge.
    static var wellGlyphSize: CGFloat { Swift.max(.iconFloor, iconBox - Metrics.space2) }
    static var controlSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var toolbarButtonSize: CGFloat { Metrics.sidebarHeaderHeight }
    /// The width of the +'s menu segment (the workspace chooser chevron): a narrow indicator
    /// joined to the + as one split button, not a third square button beside Back and Forward.
    static var toolbarMenuSegmentWidth: CGFloat { (toolbarButtonSize * 0.55).rounded() }
    /// The chooser chevron's glyph size: smaller than the +, as a menu indicator, at the +'s weight.
    static var toolbarMenuChevronPointSize: CGFloat { (Metrics.smallIconSize * 0.75).rounded() }
    static var indicatorSize: CGFloat { Metrics.statusMarkSize }
    /// A workspace row's status mark (the shared indicator, or the agent mark in its place): as
    /// tall as the unread badge beside it (Leo 2026-10-13); both read `Metrics.statusMarkSize`.
    static var statusGlyphSize: CGFloat { badgeHeight }
    static var dotSize: CGFloat { Metrics.space3 }
    /// The blue unread dot on a workspace row, an icon or a tile: 8 pt, as Claude's and ChatGPT's unread dot
    /// (Leo 2026-10-31: "INCREASE THE SIZE OF THESE BLUE DOTS ON THE SIDEBAR"). The one token every unread dot reads.
    static var unreadDotSize: CGFloat { Metrics.space4 }
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
    /// The profile control's circle at compact density (the icon box, 16 pt). The avatar lives in
    /// the row-height square, so its click target scales with the display density. #23757 grew it
    /// to the square but a hairline (22 pt); Lawrence 2026-10-21 reverted that: "bottom footer
    /// thing too big, revert to old icon sizes".
    static var avatarDiameter: CGFloat { iconBox }
    static var footerHeight: CGFloat { Metrics.sidebarRowHeightWithSubtitle - Metrics.space2 }
    /// The margin under everything the sidebar draws: the 4 pt grid step (space2 at compact). It was
    /// space4 (8 pt) since Leo 2026-10-20. Lawrence 2026-10-27 (message 13901): the footer is still too
    /// tall, so the margin is cut.
    static var bottomInset: CGFloat { Metrics.space2 }
    static var autoscrollZone: CGFloat { Metrics.sidebarRowHeight }
    /// Rows realized past each edge of the visible list. A scroll draws rows as they come in
    /// (one or two a frame), so a deep overscan bought nothing and cost every frame: each realized
    /// or parked row view is a subtree AppKit walks per scroll frame (tracking areas, layout,
    /// display), 10 rows a side made a scroll cost grow with the workspace count
    /// (sidebar-scroll-perf-DESIGN.md).
    static var overscan: CGFloat { Metrics.sidebarRowHeightWithSubtitle * 3 }
    /// Extra distance past the realization rect before a row view is parked, so a row at the
    /// edge does not park and come back on every small scroll.
    static var pruneMargin: CGFloat { Metrics.sidebarRowHeightWithSubtitle }

    /// Workspace titles: regular weight, read or unread, selected or not
    /// (Lawrence 2026-10-14: "sidebar text should not be bold by default"),
    /// and every title in the primary text color ("All titles primary"):
    /// unread shows by the badge, selection by the fill.
    static var titleFont: NSFont { sized(Typography.body, weight: .regular) }
    /// Length of the fade that ends a clipped row title (no ellipsis): 24 pt at Compact. At
    /// 16 pt the fade ended at a word gap and read as a hard cut.
    static var titleFadeWidth: CGFloat { Metrics.space6 + Metrics.space4 }
    static var subtitleFont: NSFont { sized(Typography.caption, weight: .regular) }
    /// One detail line under a row's title (the folder, branch or agent line), as its label lays it out.
    static var detailLineHeight: CGFloat {
        let font = subtitleFont
        if let detailLine, detailLine.font == font { return detailLine.height }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        detailLine = (font, height)
        return height
    }
    /// `detailLineHeight` for the last caption font: every row layout and render state reads it.
    private static var detailLine: (font: NSFont, height: CGFloat)?
    /// Section headers start on lead; content rows keep their text column without an icon.
    static var titleLeading: CGFloat { columns(rowWidth: 0).lead }
    /// The size a group header's name, glyphs, buttons and corner scale from: 26 of a 32 pt row,
    /// scaled with the row height. The colored bar itself fills the row, as tall as a workspace
    /// row (Lawrence 2026-10-19: "the height of the group headers is identical to the height of
    /// each workspace").
    static func groupHeaderContentHeight(rowHeight: CGFloat) -> CGFloat { rowHeight - 2 * (rowHeight * 0.09).rounded() }
    /// The header's name: medium weight (cx-qno.17: more contrast on the
    /// pastel bar), 14 pt on a 26 pt bar, scaled.
    static func groupHeaderFont(barHeight: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: min(15, max(11, (barHeight * 0.54).rounded())), weight: .medium)
    }
    /// The opt-in member count after a group's name (Lawrence 2026-10-20): a detail, not a title,
    /// so smaller than `name`, at the regular weight, in ``groupHeaderCountInkAlpha`` of the ink.
    static func groupHeaderCountFont(name: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: max(TypeScale.caption, name.pointSize - 2), weight: TypeScale.regular)
    }
    /// How much of the header's ink the member count takes: lighter than the name.
    static let groupHeaderCountInkAlpha: CGFloat = 0.7
    /// An archived row's ink, icon and group bar (plans/cmux-next/archiving-DESIGN.md): dimmed, still legible.
    static let archivedAlpha: CGFloat = 0.45
    /// The connected-shape prototype applies only to band headers; quiet looks keep their geometry.
    static var groupChromeShape: Bool { SidebarTunables.groupChromeShape.value && SidebarGroupHeaderStyle.tunable.value == .band }
    /// The members' line: 2 pt normally, 4 pt in the connected-shape prototype.
    static var groupBarWidth: CGFloat { groupChromeShape ? Metrics.space2 : Metrics.space1 }
    static var groupBarX: CGFloat { (Metrics.sidebarRowHeight * 0.12).rounded() }
    /// One nesting step: a nested group's rows move in this far per level below the top.
    static var groupGutter: CGFloat { groupBarX + 2 * Metrics.space1 }
    /// How far a row at group level `depth` (`SidebarRow.depth`) moves in from the list's inset.
    /// A top-level group's header and members line up with ungrouped rows: same leading x, same
    /// pill width (Leo 2026-10-21: "THE STUPID INDENT, IS THAT CHROME???? WHY IS THERE INDENT ON
    /// THIS INDENT"). Only a nested group's rows step in, one gutter per level below the first.
    static func groupOffset(depth: Int) -> CGFloat { SidebarIndent(step: groupGutter).offset(level: depth, width: .greatestFiniteMagnitude) }
    /// The members' line sits just left of their rows, in the list's leading inset for a
    /// top-level group, so no hover or selection fill covers it (cx-q5jw) and the rows keep
    /// the ungrouped rows' left edge.
    static func groupLineX(membersMinX: CGFloat) -> CGFloat { max(0, membersMinX - groupRailReach) }
    /// A group header bar's left edge over members at `membersMinX`: the rail's x less the line layout's overhang,
    /// never past the list's edge padding nor right of the members (`SidebarListView.railReach(for:)`). `inside` uses
    /// Chrome's corner geometry all the way to the list edge: the general header padding would clamp that overhang and
    /// put the line back under a member row.
    static func groupBarX(membersMinX: CGFloat) -> CGFloat {
        let edgePadding = groupLineLayout == .inside ? 0 : groupEdgePadding
        return min(membersMinX, max(max(0, groupLineX(membersMinX: membersMinX) - groupHeaderOverhang), edgePadding))
    }
    /// How far left of its members' x a group's rail starts: its width and the gap to the rows. A group
    /// header's bar reaches left by the same amount, so the rail's left edge is the bar's left edge at
    /// every level and density (Lawrence 2026-10-23: "the bar, left side, should be aligned with the
    /// header part left side"), while the header's name keeps the rows' text column.
    static var groupRailReach: CGFloat { Metrics.space1 + groupBarWidth }
    /// The least room a group header's bar and rail keep from the list's left edge (Lawrence 2026-10-25: "groups
    /// headers and rails need more left padding"): they sat flush at 0 and 2 pt. The rows' inset less the rail and
    /// its gap (`groupRailReach`; 2 pt compact, 4 pt comfortable), so the padding never eats the rail's gap: at
    /// `horizontalInset - groupBarWidth` the rail sat flush against its members' fills (Lawrence 2026-10-30, "alignment
    /// here is bad").
    static var groupEdgePadding: CGFloat { max(0, horizontalInset - groupRailReach) }
    /// The cut between a header's bar and its members' line: Chrome's (Leo 2026-10-19: "chrome has a neat little
    /// cut line"). A `joined` line has none.
    static var groupLineCut: CGFloat { Metrics.space3 }
    /// The Debug `sidebar.groupLineLayout` choice.
    static var groupLineLayout: SidebarGroupLineLayout { groupChromeShape ? .joined : SidebarGroupLineLayout.tunable.value }
    /// How far inside a header's left edge Chrome sets its line (Leo 2026-10-19: about 4 to 5 pt): the line's right
    /// edge meets the end of the bar's corner arc.
    static var groupLineCornerInset: CGFloat { max(0, rowCornerRadius - groupBarWidth) }
    /// How much further left than its rail a group header's bar reaches: `inside`, the corner inset, so the line sits
    /// under the bar's rounded corner (never past the list's edge, `SidebarListView.railReach(for:)`).
    static var groupHeaderOverhang: CGFloat { groupLineLayout == .inside ? groupLineCornerInset : 0 }
    /// The quiet group headers' color dot, in the header's leading corner (cx-25az).
    static var groupDotSize: CGFloat { max(6, (Metrics.sidebarRowHeight * 0.28).rounded()) }
    static var headerFont: NSFont { sized(Typography.header, weight: .semibold) }
    /// The count: tabular digits in the system face (a monospaced face read
    /// boxy and cramped, Leo 2026-10-13), at the shortcut size.
    static var badgeFont: NSFont { Typography.system(.monospacedDigit, size: Typography.shortcut.pointSize, weight: .medium) }
    /// How far an AppKit label cell draws its text inside its frame: a label
    /// sits this much before the edge its text aligns to.
    static var labelCellPadding: CGFloat { LayoutGrid.halfStep }
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
