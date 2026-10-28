import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20: "i made density comfortable and now it looks like this (home right side
/// is overflow maybe like it's not rounded properly)", then "width of home seems hard coded fix".
/// The pinned Home and App Store rows draw in a block row of the list; their fill must keep the
/// group header's leading and trailing inset and corner radius at every density and sidebar width,
/// also after the sidebar is resized. Since Leo 2026-10-20 (#22733) list rows end
/// `SidebarStyle.rowTrailingTrim` short of the right inset, and the pinned rows end there too.
/// The group header's bar starts left of the rows, at its members' rail (Lawrence 2026-10-23), so
/// the pinned rows start at the rows' inset, not at the bar.
@MainActor @Suite(.serialized)
struct SidebarPinnedRowWidthTests {
    static let home = LayoutItemID("itm_home"), store = LayoutItemID("itm_app_store")
    static let group = GroupID("grp-next")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(width: CGFloat) {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: SidebarPinnedRowWidthTests.home, ref: SidebarLayoutDocument.homeRef),
                                            LayoutItem(id: SidebarPinnedRowWidthTests.store, ref: .app("cmux/app-store"))])
            let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
            let members = (1...2).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "w\($0)") }
            let nodes: [SidebarNode] = [.group(SidebarGroup(id: SidebarPinnedRowWidthTests.group, name: "cmux-next app", workspaces: members))]
            model = SidebarModel(sections: [block, CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
            model.layout = SidebarLayoutDocument(sections: [top])
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                           adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 360)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            settle()
        }

        /// Resizes the sidebar as a divider drag does; the clip's frame change fits the list (`fitToClip`).
        func resize(to width: CGFloat) {
            sidebar.setFrameSize(NSSize(width: width, height: sidebar.frame.height))
            settle()
        }

        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        /// A pill's frame in the list's coordinates.
        func inList(_ layer: CALayer, of view: NSView) -> CGRect { list.convert(layer.frame, from: view) }

        func itemPill(_ id: LayoutItemID) throws -> (CGRect, CGFloat) {
            let block = try #require(list.rowViews[SidebarPinnedRowWidthTests.topKey] as? SidebarBlockRowView, "no top block")
            let row = try #require(block.region.itemViews[id], "no row for \(id)")
            row.layoutSubtreeIfNeeded()
            return (inList(row.pill, of: row), row.pill.cornerRadius)
        }

        func headerPill() throws -> (CGRect, CGFloat) {
            let header = try #require(list.rowViews[.group(SidebarPinnedRowWidthTests.group)] as? GroupHeaderRowView, "no group header")
            header.layoutSubtreeIfNeeded()
            return (inList(header.pill, of: header), header.pill.cornerRadius)
        }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var start: CGFloat
        var end: CGFloat
        var testDescription: String { "\(density) \(Int(start))→\(Int(end))" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [Case(density: density, start: 240, end: 240), Case(density: density, start: 240, end: 180),
         Case(density: density, start: 240, end: 340), Case(density: density, start: 320, end: 200)]
    }

    init() { Motion.reduceMotionOverride = true }

    /// Home and App Store fill exactly the group header's span (same inset on both sides, same radius),
    /// inside the sidebar, at the width the sidebar has now, not the one it was first laid out at.
    @Test(arguments: cases) func pinnedRowsMatchTheGroupHeader(_ c: Case) throws {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = c.density
        defer {
            DesignSettings.shared.sidebarSections.density = saved
            Motion.reduceMotionOverride = nil
        }
        let h = Harness(width: c.start)
        defer { h.window.orderOut(nil) }
        h.resize(to: c.end)
        try #require(h.list.displayed.row(for: Self.topKey) != nil, "the list draws no top block")
        let inset = SidebarDensityTokens.horizontalInset
        let width = h.list.bounds.width
        let (header, headerRadius) = try h.headerPill()
        // Since #22733 every list row ends `rowTrailingTrim` short of the right inset. Since ab905adeadd03 (Lawrence
        // 2026-10-23) a group header's bar starts at its members' rail, `groupRailReach` left of the rows, and since
        // b5400e7e342f4 (Lawrence 2026-10-25) it keeps `groupEdgePadding` from the list's edge; the pinned rows keep
        // the rows' left edge, the inset.
        let headerMinX = max(inset - SidebarStyle.groupRailReach, SidebarStyle.groupEdgePadding)
        #expect(abs(header.minX - headerMinX) < 0.5 && abs(header.maxX - (width - inset - SidebarStyle.rowTrailingTrim)) < 0.5,
                "group header \(header) does not start at its rail \(headerMinX) (and end the trim short of the inset) in \(width)")
        for id in [Self.home, Self.store] {
            let (pill, radius) = try h.itemPill(id)
            #expect(abs(pill.minX - inset) < 0.5, "\(id) starts at \(pill.minX), the rows at the inset \(inset)")
            #expect(abs(pill.maxX - header.maxX) < 0.5, "\(id) ends at \(pill.maxX), the group header at \(header.maxX) (list \(width))")
            // Since Leo 2026-10-27 a row's fill runs to `rowEdgeGap` from the sidebar's edge, never past it.
            #expect(pill.maxX <= width - SidebarStyle.rowEdgeGap + 0.5, "\(id) runs past the sidebar's edge gap: \(pill.maxX) in \(width)")
            #expect(abs(radius - headerRadius) < 0.01, "\(id) radius \(radius), the group header's \(headerRadius)")
            #expect(abs(radius - SidebarDensityTokens.rowCornerRadius) < 0.01, "\(id) radius \(radius) is not the density token")
        }
    }
}
