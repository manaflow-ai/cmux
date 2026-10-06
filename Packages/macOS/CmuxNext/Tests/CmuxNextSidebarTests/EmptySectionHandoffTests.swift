import AppKit
import Testing
@testable import CmuxNextSidebar

/// "No workspaces" stands in for a section's rows. When the first workspace
/// arrives (Cmd-N in an empty window), the placeholder leaves at once: it
/// faded out under the new row, so the two labels drew over each other for
/// about 100 ms (op-next-layout, #17485).
@MainActor @Suite struct EmptySectionHandoffTests {
    @Test func theEmptySectionLeavesAtOnceWhenItsFirstWorkspaceArrives() {
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: [])],
                                 activeWorkspaceID: nil)
        let sidebar = SidebarView(model: model)
        // No window: Motion animates for real, so a fading row stays a subview
        // until its animation ends.
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        #expect(list.subviews.contains { $0 is EmptySectionRowView })

        model.sections[0].nodes = [.workspace(w("a"))]
        model.activeWorkspaceID = id("a")
        list.reload(animated: true)

        #expect(!list.subviews.contains { $0 is EmptySectionRowView }, "no placeholder under the new row")
        #expect(list.rowViews[.workspace(id("a"))] != nil)
    }
}
