import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-13: a workspace row's text sat further in from the pill's
/// leading edge than its trailing marks did from the trailing edge, so the
/// marks crowded the right; the count badge was a boxy chip with a cramped
/// monospaced digit, taller than the status glyph beside it. One inset
/// (`SidebarStyle.horizontalInset`) now sets the pill's distance from the
/// sidebar's edges and the content's distance from the pill's, on both sides,
/// selected or not, and the badge is as tall as the glyph, with tabular digits.
/// Since Leo 2026-10-20 (#22733) the pill also stops `SidebarStyle.rowTrailingTrim`
/// short of the right inset, so its right edge never runs to the sidebar's edge;
/// the content's insets inside the pill stay equal. Since 10990df76a738 (Lawrence 2026-10-23, msg 11914: "trailing dots
/// and spinners must line up horizontally across sections") a row's last mark centers on the trailing column
/// (`SidebarStyle+TrailingColumn`, the group header chevron's x), so it ends half the column slot less half the
/// glyph further in than the leading inset. Since Leo 2026-10-27 the fill runs to `SidebarStyle.rowEdgeGap`
/// (1.5 pt) from the sidebar's right edge (a negative trim); the content's insets inside it are unchanged.
@MainActor @Suite(.serialized) struct SidebarRowGutterTests {
    private static let pinnedID = WorkspaceID("ws-pinned")
    private static let unreadID = WorkspaceID("ws-unread")
    private static let selectedID = WorkspaceID("ws-selected")

    /// Leo's rows: a pinned workspace (its section shows a header), one with
    /// a status glyph and a count, and the selected one with a status glyph.
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let pinned = SidebarWorkspace(id: pinnedID, title: "pinned")
        let unread = SidebarWorkspace(id: unreadID, title: "workspace-1", unread: .count(1), activity: .success)
        let selected = SidebarWorkspace(id: selectedID, title: "workspace-2", activity: .working(progress: nil))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .pinned, nodes: [.workspace(pinned)]),
            SidebarSection(kind: .machine(machine), nodes: [.workspace(unread), .workspace(selected)]),
        ], activeWorkspaceID: selectedID)
        // The count badge and the trailing glyph: the row badge style before the corner badge.
        model.rowBadgeStyle = .trailing
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    private static func badge(_ row: WorkspaceRowView) throws -> UnreadBadgeView {
        try #require(row.subviews.lazy.compactMap { $0 as? UnreadBadgeView }.first)
    }

    private static func glyph(_ row: WorkspaceRowView) throws -> StatusIndicatorView {
        try #require(row.subviews.lazy.compactMap { $0 as? StatusIndicatorView }.first)
    }

    /// Where the row's content starts (its leading icon slot, empty when the row has no icon),
    /// where its last trailing mark ends (the title's end in a row with no mark), and where that
    /// mark is centered (nil with no mark).
    private static func insets(_ row: WorkspaceRowView) throws -> (leading: CGFloat, trailing: CGFloat, lastMidX: CGFloat?) {
        let marks = [try badge(row), try glyph(row), row.mutedMark, row.presenceDots] as [NSView]
        guard let last = marks.filter({ !$0.isHidden && $0.frame.width > 0 }).max(by: { $0.frame.maxX < $1.frame.maxX }) else {
            return (row.icon.frame.minX, row.bounds.width - row.title.frame.maxX, nil)
        }
        return (row.icon.frame.minX, row.bounds.width - last.frame.maxX, last.frame.midX)
    }

    @Test func selectedAndUnselectedRowsHaveEqualLeadingAndTrailingInsets() throws {
        let sidebar = Self.sidebar()
        let unread = try Self.row(sidebar, Self.unreadID), selected = try Self.row(sidebar, Self.selectedID)
        #expect(selected.isSelected && !unread.isSelected)
        let gutter = SidebarStyle.horizontalInset
        // A status glyph centers on the trailing column (10990df76a738), whose slot ends `trailingColumnInset` in: the
        // larger of the row's inset and the resize band's clearance (#27954, 9a79771762c4; 7 pt at compact, the row's
        // 8 pt at comfortable). A row with no mark (the selected row: `.working` with no agent at work shows idle) runs
        // its title to the slot's end.
        let slotEnd = SidebarStyle.trailingColumnInset
        let columnTrailing = slotEnd + (SidebarStyle.trailingSlotSide - SidebarStyle.statusGlyphSize) / 2
        for (name, row) in [("unselected", unread), ("selected", selected)] {
            let (leading, trailing, lastMidX) = try Self.insets(row)
            if row === unread { #expect(lastMidX != nil, "the unread row shows its count and status glyph") }
            if row === selected { #expect(lastMidX == nil, "the selected row shows no mark (no agent at work)") }
            if let lastMidX {
                let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)
                #expect(abs(lastMidX - column) < 0.5, "\(name): the last mark centers at \(lastMidX), the trailing column at \(column)")
                #expect(abs(trailing - columnTrailing) < 0.5, "\(name): icon slot \(leading) pt in, marks \(trailing) pt in, column \(columnTrailing)")
            } else {
                #expect(trailing == slotEnd, "\(name): title ends \(trailing) pt in, the column's slot \(slotEnd) pt in")
            }
            #expect(row.title.frame.minX == gutter, "\(name): the title at the inset (no empty icon slot)")
            // The pill's own inset from the list's edges is the same token, plus the trim on the right.
            #expect(leading == gutter, "\(name): text \(leading) pt in, pill inset \(gutter)")
            #expect(row.frame.minX == gutter)
            #expect(sidebar.list.bounds.width - row.frame.maxX == gutter + SidebarStyle.rowTrailingTrim,
                    "\(name): pill ends \(sidebar.list.bounds.width - row.frame.maxX) pt in")
            // Leo 2026-10-27: the fill runs to about 1.5 pt from the sidebar's right edge.
            #expect(abs(sidebar.list.bounds.width - row.frame.maxX - SidebarStyle.rowEdgeGap) < 0.01,
                    "\(name): the fill ends \(sidebar.list.bounds.width - row.frame.maxX) pt from the edge")
        }
    }

    @Test func thePillAlignsWithTheSectionHeaderAndTheDivider() throws {
        let sidebar = Self.sidebar()
        let list = sidebar.list
        let header = try #require(list.rowViews[.section(.pinned)], "the pinned section shows a header")
        for id in [Self.unreadID, Self.selectedID] {
            let pill = list.convert(try Self.row(sidebar, id).frame, to: sidebar)
            let headerFrame = list.convert(header.frame, to: sidebar)
            #expect(pill.minX == headerFrame.minX, "pill \(pill.minX), header \(headerFrame.minX)")
            // The divider runs to the inset; the pill stops the trim short of it (#22733).
            #expect(pill.maxX == sidebar.aboveLine.frame.maxX - SidebarStyle.rowTrailingTrim,
                    "pill \(pill.maxX), divider \(sidebar.aboveLine.frame.maxX)")
            #expect(pill.minX == sidebar.aboveLine.frame.minX, "pill \(pill.minX), divider \(sidebar.aboveLine.frame.minX)")
        }
    }

    @Test func theCountBadgeIsAsTallAsTheStatusGlyphWithTabularDigits() throws {
        let sidebar = Self.sidebar()
        let row = try Self.row(sidebar, Self.unreadID)
        let badge = try Self.badge(row), glyph = try Self.glyph(row)
        #expect(!badge.isHidden && !glyph.isHidden)
        #expect(badge.frame.height == glyph.frame.height, "badge \(badge.frame.height) pt, glyph \(glyph.frame.height) pt")
        #expect(badge.frame.midY == glyph.frame.midY)
        let font = SidebarStyle.badgeFont
        let widths = Set((0...9).map { ("\($0)" as NSString).size(withAttributes: [.font: font]).width })
        #expect(widths.count == 1, "digits are not tabular: \(widths.sorted())")
        // Tabular digits in the system face, not a monospaced face.
        #expect(!font.isFixedPitch, "\(font.fontName) is monospaced throughout")
    }
}
