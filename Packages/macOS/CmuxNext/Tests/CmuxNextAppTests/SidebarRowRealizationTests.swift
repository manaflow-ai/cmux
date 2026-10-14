import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The macOS 27 lane (2026-10-13): `WorkspaceRowHoverMotionTests` found no
/// view for its only workspace row. The list builds its rows (`reload`) when
/// the sidebar is made, before it has a size, and realizes row views only
/// inside the viewport; when the viewport then gets its size, no row view was
/// made until a scroll or the next reload. A sidebar that gets its size after
/// its rows shows them at once.
@MainActor @Suite(.serialized) struct SidebarRowRealizationTests {
    @Test func rowsLoadedBeforeTheSidebarHasASizeShowOnceItHasOne() throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (1...3).map { WorkspaceID("ws-\($0)") }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ], activeWorkspaceID: nil)
        // The rows load here, with no size yet.
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.list.reload(animated: false)
        let loaded = sidebar.list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        try #require(loaded.count == 3, "the rows did not load")

        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        for id in ids {
            #expect(sidebar.list.rowViews[.workspace(id)] is WorkspaceRowView, "\(id.rawValue) has no row view once the sidebar has a size")
        }
    }
}
