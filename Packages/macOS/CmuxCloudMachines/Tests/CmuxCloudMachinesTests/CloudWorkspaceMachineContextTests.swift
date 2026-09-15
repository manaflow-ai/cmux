import Foundation
import Testing
@testable import CmuxCloudMachines

struct CloudWorkspaceMachineContextTests {
    @Test func focusedMachinesSelectionWinsAndLocalSelectionStaysLocal() {
        #expect(
            CloudWorkspaceMachineContext(
                selection: .cloud("machine-b"),
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .cloud("machine-b")
        )
        #expect(
            CloudWorkspaceMachineContext(
                selection: .local,
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .local
        )
        #expect(
            CloudWorkspaceMachineContext(
                selection: .pending,
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .unavailable
        )
        #expect(
            CloudWorkspaceMachineContext(
                selection: .none,
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .local
        )
    }

    @Test func workspaceBindingWinsWhenMachinesPanelDoesNotOwnFocus() {
        #expect(
            CloudWorkspaceMachineContext(
                selection: .cloud("machine-b"),
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: false
            ).target == .cloud("machine-a")
        )
        #expect(
            CloudWorkspaceMachineContext(
                selection: .none,
                selectedWorkspaceCloudMachineID: nil,
                machinesPanelOwnsFocus: false
            ).target == .local
        )
    }
}
