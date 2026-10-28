import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// The creates' pending rows belong to the app's services (the composition root), not to the process: a second
/// `AppServices` (a test's, another launch's) never sees or takes the first one's rows.
@MainActor @Suite(.serialized)
struct PendingWorkspaceRowsOwnerTests {
    private func row(_ id: String, window: String) -> PendingWorkspaceRows.Row {
        let machine = CmuxNextSidebar.MachineID.local
        return .init(id: id, window: window, machine: machine,
                     face: SidebarMapping.shared.creatingRow(id: id, machine: machine, name: "workspace-1", opensPage: true),
                     slot: nil, byDefault: nil)
    }

    @Test func eachServicesKeepsItsOwnRows() {
        _ = NSApplication.shared
        let first = AppServices(environment: AppEnvironment.current([:]))
        let second = AppServices(environment: AppEnvironment.current([:]))
        first.pendingWorkspaceRows.add(row("ws-1", window: "w1"), name: "workspace-1")
        #expect(first.pendingWorkspaceRows.rows(in: "w1").map(\.id) == ["ws-1"])
        #expect(second.pendingWorkspaceRows.rows(in: "w1").isEmpty)
        #expect(first.pendingWorkspaceRows !== second.pendingWorkspaceRows)
        first.pendingWorkspaceRows.remove("ws-1")
    }
}
