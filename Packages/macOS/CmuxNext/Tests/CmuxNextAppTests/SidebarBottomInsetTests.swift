import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: the sidebar's bottom (the account row, the last rows and the list's scroller)
/// sat on the window's bottom edge. The sidebar keeps a margin under everything it draws: the 4 pt
/// grid step (space2 at compact) since f2f5f98c133 (Lawrence 2026-10-27, message 13901: the footer
/// was still too tall), space4 (8 pt) before.
@MainActor @Suite(.serialized) struct SidebarBottomInsetTests {
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = (1...40).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows)]), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func nothingTheSidebarDrawsTouchesItsBottomEdge() {
        let sidebar = Self.sidebar()
        #expect(Metrics.space2 > 0, "a margin at all")
        let floor = sidebar.bounds.height - Metrics.space2
        // The view is flipped: maxY is the bottom.
        #expect(sidebar.footerRegion.frame.maxY <= floor + 0.5, "the pinned footer section (account row) keeps the margin")
        let list = sidebar.scrollView.convert(sidebar.scrollView.bounds, to: sidebar)
        #expect(list.maxY <= floor + 0.5, "the list and its scroller keep the margin")
    }
}
