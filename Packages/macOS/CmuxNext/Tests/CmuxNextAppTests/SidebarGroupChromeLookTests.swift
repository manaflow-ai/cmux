import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Testing

/// cg-design-judge's fixes to the shipped Chrome-style group look (2026-10-14, the sidebar
/// groups Thunderdome): a collapsed header says how many workspaces it holds, the members' line
/// starts under the header bar instead of cutting its rounded corner (flat-ended since Leo's Chrome reference), the header's ink is white
/// or near-black on the group's color, and the header's name starts on the ungrouped rows' column.
@MainActor @Suite(.serialized) struct SidebarGroupChromeLookTests {
    static let open = GroupID("grp-open")
    static let closed = GroupID("grp-closed")

    @Test func aCollapsedHeaderShowsItsMemberCount() throws {
        let (sidebar, _) = try Self.sidebar()
        let closed = try #require(sidebar.list.rowViews[.group(Self.closed)] as? GroupHeaderRowView)
        let open = try #require(sidebar.list.rowViews[.group(Self.open)] as? GroupHeaderRowView)
        closed.layoutSubtreeIfNeeded()
        open.layoutSubtreeIfNeeded()
        #expect(closed.countText == "2", "a collapsed group of 2 shows \(closed.countText ?? "no count")")
        #expect(open.countText == nil, "an open group shows its members, not a count")
    }

    @Test func aCollapsedHeadersCountDrawsWhole() throws {
        let (sidebar, _) = try Self.sidebar()
        let header = try #require(sidebar.list.rowViews[.group(Self.closed)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        let count = header.countLabel
        try #require(!count.isHidden && count.frame.width > 0)
        // The count as laid out, against the same label with room to spare: a frame cut to the
        // label's bare measured width clips the digit's last pixels (or truncates it).
        let laidOut = Self.ink(count, width: count.frame.width)
        let roomy = Self.ink(count, width: count.frame.width + 40)
        #expect(roomy > 0)
        #expect(laidOut >= roomy * 0.999, "the count draws \(laidOut) of its \(roomy) ink in a \(count.frame.width) pt frame")
    }

    @Test func theMembersLineStartsUnderTheHeaderBarFlat() throws {
        let (sidebar, _) = try Self.sidebar()
        let header = try #require(sidebar.list.rowViews[.group(Self.open)] as? GroupHeaderRowView)
        let line = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first)
        let head = sidebar.convert(header.bounds, from: header)
        let drawn = sidebar.convert(line.bounds, from: line)
        let bar = head.height // the bar fills the header's row (SidebarGroupHeaderHeightTests)
        // The sidebar is flipped or not; the bar's edge nearest the members is the one the line meets.
        let flipped = sidebar.isFlipped
        let barEdge = flipped ? head.midY + bar / 2 : head.midY - bar / 2
        let lineStart = flipped ? drawn.minY : drawn.maxY
        #expect(flipped ? lineStart > barEdge : lineStart < barEdge,
                "the line starts at \(lineStart), inside the header bar that ends at \(barEdge)")
        line.layoutSubtreeIfNeeded()
        // Chrome's square left edge and body keep their flat geometry; the top-right edge is the cut/taper.
        #expect(line.layer?.cornerRadius == 0 && line.layer?.masksToBounds == true && line.railShape.path != nil,
                "the line has the clipped Chrome corner cut")
        #expect(line.railShape.frame.width == 2 && line.railShape.frame.height >= 4096,
                "the cut shape preserves coverage while the parent rail shrinks")
    }

    @Test func aHeaderInkIsWhiteOrNearBlackWhicheverReadsBetter() throws {
        let nearBlack = ThemeRGB(hex: 0x1F1F1F)
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar(GroupPaletteDefaultTests.order)
            scope.root(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            for (id, color) in zip(ids, GroupPaletteDefaultTests.order) {
                let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
                header.layoutSubtreeIfNeeded()
                header.updateLayer()
                let bar = try #require(header.layer?.sublayers?.first { $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 })
                let fill = try GroupPaletteDefaultTests.rgb(bar.backgroundColor)
                let ink = try GroupPaletteDefaultTests.rgb(header.ink?.cgColor)
                let best = nearBlack.contrast(with: fill) >= ThemeRGB.white.contrast(with: fill) ? nearBlack : ThemeRGB.white
                #expect(GroupPaletteDefaultTests.same(ink, best), "\(name) \(color): ink \(ink) on \(fill), want \(best)")
                #expect(ink.contrast(with: fill) >= 4.5, "\(name) \(color): ink contrast \(ink.contrast(with: fill))")
            }
        }
    }

    @Test func aHeaderNameStartsOnTheUngroupedRowsColumn() throws {
        let (sidebar, loose) = try Self.sidebar()
        let header = try #require(sidebar.list.rowViews[.group(Self.open)] as? GroupHeaderRowView)
        let row = try #require(sidebar.list.rowViews[.workspace(loose)] as? WorkspaceRowView)
        header.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        let name = sidebar.convert(header.titleFrame, from: header).minX + Metrics.space1
        // An ungrouped row's leading column: its icon slot, drawn or empty (every row keeps one,
        // Lawrence 2026-10-21), so the header's name and every row's icon share one x.
        let column = sidebar.convert(row.icon.frame, from: row).minX
        #expect(abs(name - column) < 0.5, "the header's name starts at \(name), the ungrouped rows at \(column)")
    }

    // MARK: Fixtures

    /// How much a label draws (its pixels' summed alpha) at `width`; the label keeps its frame.
    static func ink(_ label: NSView, width: CGFloat) -> Double {
        let frame = label.frame
        defer { label.frame = frame }
        label.frame.size.width = width
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return 0 }
        label.cacheDisplay(in: label.bounds, to: rep)
        var total = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh { total += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
        }
        return total
    }

    /// One ungrouped workspace, then an open group and a collapsed group of two each.
    static func sidebar() throws -> (SidebarView, WorkspaceID) {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: (0..<5).map { index in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: "ws-\(index)"), name: "w\(index)")
        }))
        let section = try #require(SidebarMapping.shared.sections(store.sidebarSections,
                                                                   machine: SidebarMachine(id: .local, name: "This Mac", kind: .local)).first)
        let w = section.workspaces
        try #require(w.count == 5)
        let nodes: [CmuxNextSidebar.SidebarNode] = [
            .workspace(w[0]),
            .group(SidebarGroup(id: open, name: "Backend", color: .green, workspaces: [w[1], w[2]])),
            .group(SidebarGroup(id: closed, name: "Infra", color: .orange, isCollapsed: true, workspaces: [w[3], w[4]])),
        ]
        // The member count is opt-in (`sidebar.groupHeader.memberCount`, Lawrence 2026-10-20).
        let design = DesignSettings()
        design.sidebarSections.groupHeaderMemberCount = true
        let sidebar = SidebarView(model: SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: nodes)]),
                                  design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        // The settings reach the list on an observation a turn later; draw them in this turn.
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, w[0].id)
    }
}
