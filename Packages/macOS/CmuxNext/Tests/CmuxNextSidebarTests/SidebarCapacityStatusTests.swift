@testable import CmuxNextSidebar
import Testing

struct SidebarCapacityStatusTests {
    @Test func capacityStatusShowsOnAnOtherwiseOneLineRow() {
        let options = SidebarLayoutOptions()
        var workspace = SidebarWorkspace(id: WorkspaceID("capacity"), title: "Claude chat")
        #expect(options.rowContent(workspace, machine: nil).detail == nil)

        workspace.capacityWaitCount = 2
        let waiting = options.rowContent(workspace, machine: nil)
        #expect(waiting.detail == "Waiting for capacity (2)")
        #expect(SidebarLayoutMetrics.standard.height(for: waiting) > SidebarLayoutMetrics.standard.rowHeight)

        workspace.capacityWaitCount = 0
        #expect(options.rowContent(workspace, machine: nil).detail == nil)
    }
}
