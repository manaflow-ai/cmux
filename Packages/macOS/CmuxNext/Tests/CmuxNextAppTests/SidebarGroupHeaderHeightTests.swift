import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-19: "Make sure the height of the group headers is identical to the height of
/// each workspace row." The header's slot was already a row tall, but its colored bar was inset
/// top and bottom (20 of 24 pt, 22 of 28, 16 of 20 in Minimal Mode), so a header read shorter
/// than the selected or hovered workspace row under it. The bar now fills its row, and the layout
/// takes one row height for headers and workspace rows.
@MainActor @Suite(.serialized) struct SidebarGroupHeaderHeightTests {
    private static let group = GroupID("grp-height")
    private static let member = WorkspaceID("ws-member")
    private static let loose = WorkspaceID("ws-loose")

    private static func sidebar(minimal: Bool, collapsed: Bool) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: collapsed,
                                    workspaces: [SidebarWorkspace(id: member, title: "member")])),
                .workspace(SidebarWorkspace(id: loose, title: "loose")),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.minimal = minimal
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// The header's colored bar: its full-width rounded layer.
    private static func barHeight(_ header: GroupHeaderRowView) throws -> CGFloat {
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        let bar = try #require(header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 })
        return bar.frame.height
    }

    @Test(arguments: [false, true], [false, true])
    func aGroupHeaderIsAsTallAsAWorkspaceRow(minimal: Bool, collapsed: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal, collapsed: collapsed)
        let headerSlot = try #require(sidebar.list.displayed.row(for: .group(Self.group))).height
        let rowSlot = try #require(sidebar.list.displayed.row(for: .workspace(Self.loose))).height
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        let row = try #require(sidebar.list.rowViews[.workspace(Self.loose)] as? WorkspaceRowView)
        let bar = try Self.barHeight(header)
        let label = "minimal \(minimal), collapsed \(collapsed): header slot \(headerSlot), bar \(bar), row slot \(rowSlot), row view \(row.frame.height)"
        #expect(abs(headerSlot - rowSlot) <= 0.5, "\(label)")
        #expect(abs(header.frame.height - row.frame.height) <= 0.5, "\(label)")
        #expect(abs(bar - row.frame.height) <= 0.5, "the header's bar is shorter than a workspace row: \(label)")
        if !collapsed {
            let memberSlot = try #require(sidebar.list.displayed.row(for: .workspace(Self.member))).height
            #expect(abs(memberSlot - headerSlot) <= 0.5, "\(label), member slot \(memberSlot)")
        }
    }

    /// Every density's one-line row height: Minimal Mode at compact (20), compact (24), comfortable (28).
    @Test(arguments: [CGFloat(20), 24, 28])
    func theBarFillsItsRowAtEveryDensity(rowHeight: CGFloat) throws {
        let header = GroupHeaderRowView(key: .group(Self.group))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: rowHeight)
        let bar = try Self.barHeight(header)
        #expect(abs(bar - rowHeight) <= 0.5, "a \(rowHeight) pt row draws a \(bar) pt bar")
    }

    @Test func layoutMetricsUseOneRowHeightForHeadersAndRows() {
        for m in [SidebarLayoutMetrics.standard, SidebarLayoutMetrics.standard.minimal] {
            #expect(m.groupHeaderHeight == m.rowHeight)
        }
    }
}
