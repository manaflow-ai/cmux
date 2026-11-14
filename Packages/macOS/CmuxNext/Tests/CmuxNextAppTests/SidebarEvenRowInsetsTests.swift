import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-05: "too much padding on right. padding on left/right of every workspace needs to be even."
/// Measured in the running app (compact, 2x): a pinned row's pin started 6 pt inside its fill, but its spinner's ink
/// ended 9 pt before the fill's end. The trailing column centered `horizontalInset` plus half the 14 pt status mark
/// box inside the fill, so a glyph drawn smaller than that box stopped short of the row's inset.
///
/// The trailing twin of `SidebarLeadingEdgeTests` (every row's first ink starts at the row inset): every workspace
/// row (a pinned band row, a Pinned section row, a top-level group's member, a loose row, the selected row, a hovered
/// row showing its ×) keeps its fill as far from the list's right edge as from its left, and its last trailing glyph
/// box ends the row inset before the fill's end, as its leading glyph box starts the row inset after the fill's start
/// (box against box: each glyph's own padding inside its box is the same on both sides). A hovered row's ✕, a control
/// slot wider than its glyph, centers on that same column.
@MainActor @Suite(.serialized) struct SidebarEvenRowInsetsTests {
    private static let pinnedID = WorkspaceID("even-pinned")
    private static let groupedID = WorkspaceID("even-grouped")
    private static let looseID = WorkspaceID("even-loose")
    private static let erroredID = WorkspaceID("even-errored")
    private static let hoveredID = WorkspaceID("even-hovered")
    private static let selectedID = WorkspaceID("even-selected")
    /// Device pixels at 2x: frames snap to half points (as `SidebarLeadingEdgeTests`).
    private static let tolerance: CGFloat = 0.5

    /// One workspace of each kind, each showing a status mark, so each row has a last trailing ink to measure.
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func workspace(_ id: WorkspaceID, _ title: String, _ activity: StatusIndicatorState = .success) -> SidebarWorkspace {
            SidebarWorkspace(id: id, title: title, activity: activity)
        }
        let group = SidebarGroup(id: GroupID("even-group"), name: "Group",
                                 workspaces: [workspace(groupedID, "grouped")])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(workspace(pinnedID, "pinned"))]),
            SidebarSection(kind: .machine(machine), nodes: [
                .group(group),
                .workspace(workspace(looseID, "loose")),
                .workspace(workspace(erroredID, "errored", .error)),
                .workspace(workspace(hoveredID, "hovered")),
                .workspace(workspace(selectedID, "selected")),
            ]),
        ], activeWorkspaceID: selectedID)
        model.rowBadgeStyle = .trailing
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView, "no row for \(id)")
    }

    /// The row's last visible trailing view (a status mark, a count, the hover ×), the one nearest the fill's end.
    private static func lastTrailingView(_ row: NSView, excluding: [NSView]) -> NSView? {
        row.subviews.filter { candidate in
            !candidate.isHidden && candidate.alphaValue > 0 && candidate.frame.width > 0 && !excluding.contains { $0 === candidate }
                && candidate.frame.minX > row.bounds.midX
        }.max { $0.frame.maxX < $1.frame.maxX }
    }

    @Test func everyWorkspaceListRowHasEvenOuterAndInnerInsets() throws {
        let sidebar = Self.sidebar()
        let hovered = try Self.row(sidebar, Self.hoveredID)
        hovered.isHovered = true
        hovered.layoutSubtreeIfNeeded()
        let list = sidebar.list
        let inset = SidebarStyle.contentInset
        for (name, id) in [("pinned", Self.pinnedID), ("grouped", Self.groupedID), ("loose", Self.looseID),
                           ("errored", Self.erroredID), ("hovered", Self.hoveredID), ("selected", Self.selectedID)] {
            let row = try Self.row(sidebar, id)
            if id == Self.selectedID { #expect(row.isSelected) }
            let left = row.frame.minX, right = list.bounds.width - row.frame.maxX
            #expect(abs(left - right) < 0.01, "\(name): the fill is \(left) pt from the list's left edge, \(right) pt from its right")
            // The leading glyph's box (the icon slot, else the title) starts the row inset inside the fill.
            let leading = row.icon.frame.width > 0 ? row.icon.frame.minX : row.title.frame.minX
            #expect(abs(leading - inset) < 0.01, "\(name): the leading box starts \(leading) pt inside the fill, the row inset \(inset)")
            let last = try #require(Self.lastTrailingView(row, excluding: [row.title, row.icon]), "\(name) shows no trailing view")
            if id == Self.hoveredID {
                // The hover ✕ is a control slot wider than its glyph: it takes the status mark's place on the column.
                let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)
                #expect(abs(last.frame.midX - column) <= Self.tolerance,
                        "hovered: the last control (\(type(of: last)) \(last.frame)) centers at \(last.frame.midX), the column at \(column)")
                continue
            }
            // The trailing glyph's box (the status mark, sized to the glyph) ends that inset before the fill's end.
            let trailing = row.bounds.width - last.frame.maxX
            #expect(abs(trailing - leading) <= Self.tolerance,
                    "\(name): the leading box starts \(leading) pt inside the fill, the last mark (\(type(of: last)) \(last.frame)) ends \(trailing) pt before its end")
        }
    }

    /// A pinned workspace in the band above the list (`SidebarItemRowView`): its fill keeps one gap on both sides, and
    /// its status mark's box ends the row inset before the fill's end, where the pin's box starts after its start.
    @Test func aPinnedBandRowHasEvenOuterAndInnerInsets() throws {
        let bandRow = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: SidebarRowTokens.current.band.rowHeight))
        bandRow.wantsLayer = true
        var info = SidebarItemInfo(title: "cmux perf lead", symbol: "square")
        info.leadingPin = true
        info.activity = .success
        bandRow.configure(info, style: .builtIn)
        bandRow.layoutSubtreeIfNeeded()
        bandRow.layout()
        let pill = bandRow.pill.frame
        #expect(abs(pill.minX - (bandRow.bounds.width - pill.maxX)) < 0.01,
                "the fill is \(pill.minX) pt from the row's left edge, \(bandRow.bounds.width - pill.maxX) pt from its right")
        #expect(!bandRow.activity.isHidden && bandRow.activity.frame.width > 0, "the row shows its status mark")
        let trailing = pill.maxX - bandRow.activity.frame.maxX
        #expect(abs(trailing - SidebarStyle.contentInset) <= Self.tolerance,
                "the mark (\(bandRow.activity.frame)) ends \(trailing) pt before the fill's end (\(pill)), the content inset \(SidebarStyle.contentInset)")
    }

    /// Lawrence 2026-11-09: "for each workspace row, padding on left/bottom/top/right should be even, on all
    /// densities". A one-line row's content keeps one padding on all four sides of its fill: its first glyph starts it
    /// inside the fill's left edge, its last trailing box ends it before the right edge, and its title's capitals sit
    /// it below the top edge with its baseline it above the bottom (the ink a person sees; the row centers its
    /// capitals). Before, the sides took the row inset (6 compact, 8 comfortable) while the text had about 7.5 and 9.5
    /// above and below it.
    @Test(arguments: [SidebarDensity.compact, .comfortable])
    func aOneLineRowsContentHasOnePaddingOnEverySide(_ density: SidebarDensity) throws {
        try SidebarGroupRailAlignmentTests.with(density, .off) {
            let sidebar = Self.sidebar()
            let hovered = try Self.row(sidebar, Self.hoveredID)
            hovered.isHovered = true
            hovered.layoutSubtreeIfNeeded()
            for (name, id) in [("loose", Self.looseID), ("selected", Self.selectedID), ("hovered", Self.hoveredID)] {
                let row = try Self.row(sidebar, id)
                let font = row.title.font
                let scale = row.window?.backingScaleFactor ?? 2
                let baseline = row.title.frame.minY + (font.ascender * scale).rounded() / scale
                let top = baseline - font.capHeight, bottom = row.bounds.height - baseline
                let left = row.title.frame.minX
                let last = try #require(Self.lastTrailingView(row, excluding: [row.title, row.icon]), "\(name) shows no trailing view")
                let right = id == Self.hoveredID
                    ? row.bounds.width - SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width) - SidebarStyle.statusGlyphSize / 2
                    : row.bounds.width - last.frame.maxX
                let sides = [("top", top), ("bottom", bottom), ("right", right)]
                for (side, value) in sides {
                    #expect(abs(value - left) <= 0.75,
                            "\(density.rawValue) \(name): the content starts \(left) pt inside the fill's left edge, \(value) pt inside its \(side) edge")
                }
            }
        }
    }

    /// Expanded rows keep the same padding left and right, and their one leading edge is the compact list's.
    @Test func anExpandedRowsSidesMatch() throws {
        try SidebarGroupRailAlignmentTests.with(.expanded, .off) {
            let sidebar = Self.sidebar()
            let row = try Self.row(sidebar, Self.looseID)
            let last = try #require(Self.lastTrailingView(row, excluding: [row.title, row.icon, row.subtitle]), "no trailing view")
            let left = row.title.frame.minX, right = row.bounds.width - last.frame.maxX
            #expect(abs(left - right) <= Self.tolerance, "expanded: the content starts \(left) pt inside the left edge, ends \(right) before the right")
        }
    }
}
