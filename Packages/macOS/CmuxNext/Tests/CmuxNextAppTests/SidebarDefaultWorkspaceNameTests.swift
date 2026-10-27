import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// #21357: a new workspace's row showed no title. A terminal workspace gets no
/// page or agent title, so hiding the daemon's `workspace-N` name left the row
/// blank until the user renamed it.
@MainActor
struct SidebarDefaultWorkspaceNameTests {
    private static func rows(names: [String]) -> [SidebarWorkspace] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: names.enumerated().map { index, name in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\(index + 1)"), name: name)
        }))
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        return sections.flatMap(\.workspaces)
    }

    @Test func aWorkspaceWithTheDaemonDefaultNameShowsIt() {
        #expect(Self.rows(names: ["workspace-1", "workspace-2"]).map(\.title) == ["workspace-1", "workspace-2"])
    }

    @Test func aCreatingRowShowsTheNameItWillHave() {
        let row = SidebarMapping.shared.creatingRow(id: "pending", machine: .local, name: "workspace-3", opensPage: false)
        #expect(row.title == "workspace-3")
    }
}
