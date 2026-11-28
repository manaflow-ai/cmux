import AppKit
import CmuxNextDesign

/// Where a row sits across the list: its inset, its indent and a group header's reach over its rail.
extension SidebarListViewComponents {
    /// What a row's frame reads besides the row itself: the list's width, its row inset and trailing trim, and the
    /// indent rule. The inset is derived from the density, text size and glyph size on every read, and a frame read
    /// it up to six times: a pass over the realized rows (`realizeVisibleRows`, `pruneOffscreen`, a width change)
    /// spent most of its time there, on every status tick and workspace switch. Such a pass reads it once.
    struct RowGeometry {
        let width: CGFloat
        let inset: CGFloat
        let trailingTrim: CGFloat
        let indent: SidebarIndent
        /// Whether a group header reaches over its members' rail (no plain folder, no card).
        let headersReach: Bool
        /// The width a level-0 row has: the indent cap is computed from it.
        var indentWidth: CGFloat { max(0, width - inset * 2 - trailingTrim) }
    }
    /// The pass over many rows running now (``withRowGeometry(_:)``), and how often ``inset`` was read.
    struct RowGeometryPass {
        /// The row geometry the pass read once; nil between passes.
        var geometry: RowGeometry?
        /// Reads of ``inset``: a pass over the realized rows reads it once, not per row.
        var insetReads = 0
    }
    /// The list's row inset (``SidebarStyle/horizontalInset``). Each read derives it from the density, the text size and
    /// the glyph size, so a pass over many rows reads it once (``withRowGeometry(_:)``).
    var inset: CGFloat {
        geometryPass.insetReads += 1
        return SidebarStyle.horizontalInset
    }
    /// Reads of ``inset`` (`SidebarRowGeometryTests`).
    var insetReads: Int { geometryPass.insetReads }
    /// The row geometry of the pass over many rows running now; nil between passes.
    var passRowGeometry: RowGeometry? { geometryPass.geometry }
    /// The row geometry now: the pass's (``withRowGeometry(_:)``) while one runs at this width, else read fresh.
    var rowGeometry: RowGeometry {
        if let pass = passRowGeometry, pass.width == bounds.width { return pass }
        let indent = indent
        return RowGeometry(width: bounds.width, inset: inset, trailingTrim: SidebarStyle.rowTrailingTrim, indent: indent,
                           headersReach: !indent.indentsTopLevel && !model.groupHeaderDetails.background.drawsCard)
    }
    /// Runs `body`, a pass over many rows, with the row geometry read once for all of them. A width change inside it
    /// reads the geometry again (``rowGeometry``).
    func withRowGeometry<T>(_ body: () -> T) -> T {
        if let pass = passRowGeometry, pass.width == bounds.width { return body() }
        let outer = passRowGeometry
        geometryPass.geometry = rowGeometry
        defer { geometryPass.geometry = outer }
        return body()
    }
    func frame(for row: SidebarRow) -> NSRect {
        // A block's region draws its own insets, as the band did.
        if case .block = row.key { return NSRect(x: 0, y: row.y, width: bounds.width, height: row.height) }
        let geometry = rowGeometry
        // The one indent rule (`SidebarIndent`): from the drawn tree, a top-level group's rows flush with ungrouped
        // rows (#23975), each deeper level one gutter in, capped in a narrow list.
        let gutter = indentOffset(for: row, in: geometry)
        // A group header reaches left over its members' rail (`groupRailReach`): the rail and the bar share one left edge.
        let reach = railReach(for: row, in: geometry)
        // Rows end `rowTrailingTrim` short of the list's right inset, so a row's pill never runs to
        // the sidebar's edge (Leo 2026-10-20, Chrome's vertical tabs).
        return NSRect(x: geometry.inset + gutter - reach, y: row.y,
                      width: max(0, geometry.width - geometry.inset * 2 - gutter - geometry.trailingTrim) + reach, height: row.height)
    }
    /// How far left of its members' x `row` starts: a group header's reach over its rail (`SidebarStyle.groupLineX`)
    /// and the line layout's overhang past it (`groupHeaderOverhang`), never past the list's edge; 0 for other rows.
    func railReach(for row: SidebarRow) -> CGFloat {
        guard case .group = row.key else { return 0 }
        return railReach(for: row, in: rowGeometry)
    }
    private func railReach(for row: SidebarRow, in geometry: RowGeometry) -> CGFloat {
        // A plain folder draws no rail, nor does a card (its block wraps the rows): the header keeps the rows' own frame.
        guard case .group = row.key, geometry.headersReach else { return 0 }
        let membersX = geometry.inset + indentOffset(for: row, in: geometry)
        return membersX - SidebarStyle.groupBarX(membersMinX: membersX)
    }
    /// The indent rule every row, rail, lifted card and drop line of this list uses.
    var indent: SidebarIndent {
        let folders = model.groupHeaderDetails.background.indentsMembers
        return SidebarIndent(step: folders ? SidebarStyle.folderMemberStep : SidebarStyle.groupGutter, indentsTopLevel: folders)
    }
    /// The width a level-0 row has: the indent cap is computed from it.
    var indentWidth: CGFloat { rowGeometry.indentWidth }
    /// How far `row` moves in from the list's inset.
    func indentOffset(for row: SidebarRow) -> CGFloat { indentOffset(for: row, in: rowGeometry) }
    private func indentOffset(for row: SidebarRow, in geometry: RowGeometry) -> CGFloat {
        let indent = geometry.indent
        // A folder's header sits at its parent's members' x, one step left of its own members (a group header
        // shares its members' level, `SidebarRow.indentLevel`).
        let level = indent.indentsTopLevel && row.key.isGroupHeader ? row.indentLevel - 1 : row.indentLevel
        return indent.offset(level: level, width: geometry.indentWidth)
    }
}
