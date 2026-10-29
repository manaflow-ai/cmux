import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudNewWorkspaceEntryTests {
    @Test func sidebarPlusRunsTheSameUserActionAsCommandNInItsOwnWindow() throws {
        let services = MachineIconTests.services()
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"cloud-plus","workspace_key":"plus-home"}"#.utf8))
        let state = WindowState(record: record)
        let bridge = SidebarBridge(services: services, state: state)
        var calls: [ActionInvocation] = []
        let bound = services.registry.bind("newTab", invoke: { calls.append($0) })
        #expect(bound)
        bridge.handle(.newWorkspace(machine: nil, group: nil))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.origin == .user)
        #expect(call.target == ActionTargetRef(kind: .window, id: state.id))
    }
}
