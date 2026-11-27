import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-03: "why when i collapse/expand the cosmic-gray group do the workspace horizontal widths differ?"
/// Open, a long group overflowed the list and a legacy scroller (macOS "Show scroll bars: Always", or a mouse
/// attached) took its width from the clip, so every row, the group's header too, drew narrower than with the
/// group folded. The rows' width now counts the scroller for its style and never for whether it shows.
@MainActor @Suite(.serialized) struct SidebarGroupFoldKeepsRowWidthTests {
    private static let group = GroupID("grp-fold-width")
    private static let loose = WorkspaceID("ws-loose")

    private static func sidebar(collapsed: Bool, style: NSScroller.Style) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let members = (0..<40).map { SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "member \($0)") }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cosmic-gray", isCollapsed: collapsed, workspaces: members)),
                .workspace(SidebarWorkspace(id: loose, title: "loose")),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        // What AppKit leaves on a scroll view with "Show scroll bars: Always" until the overlay style is put back.
        sidebar.scrollView.scrollerStyle = style
        sidebar.scrollView.tile()
        sidebar.list.fitToClip()
        return sidebar
    }

    private static func frames(collapsed: Bool, style: NSScroller.Style) throws -> (header: NSRect, row: NSRect) {
        let list = sidebar(collapsed: collapsed, style: style).list
        let header = try #require(list.displayed.row(for: .group(group)))
        let row = try #require(list.displayed.row(for: .workspace(loose)))
        return (list.frame(for: header), list.frame(for: row))
    }

    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func foldingAGroupKeepsItsHeaderAndTheRowsAtOneWidth(style: NSScroller.Style) throws {
        let open = try Self.frames(collapsed: false, style: style)
        let folded = try Self.frames(collapsed: true, style: style)
        #expect(open.header.minX == folded.header.minX, "the header moved sideways: \(open.header) vs \(folded.header)")
        #expect(open.header.width == folded.header.width, "the header changed width: \(open.header) vs \(folded.header)")
        #expect(open.row.minX == folded.row.minX && open.row.width == folded.row.width,
                "a workspace row changed width: \(open.row) vs \(folded.row)")
    }
}
