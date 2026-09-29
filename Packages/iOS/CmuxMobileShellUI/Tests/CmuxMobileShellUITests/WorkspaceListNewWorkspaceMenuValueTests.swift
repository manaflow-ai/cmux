import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListNewWorkspaceMenuValueTests {
    @Test func loneConnectedCloudTargetRemainsAValidCreationTarget() {
        let target = WorkspaceListNewWorkspaceMenuValue.ComputerTarget(
            id: "cloud-1",
            kind: .cloud(hostID: "cloud-1"),
            name: "Cloud",
            isConnected: true,
            systemImage: "cloud"
        )
        let value = WorkspaceListNewWorkspaceMenuValue(
            canCreate: false,
            canCreateGroup: false,
            computerTargets: [target]
        )

        #expect(value.isEnabled)
        #expect(value.singleConnectedTarget == target)
    }

    @Test func disconnectedSingleTargetDoesNotEnableDirectCreation() {
        let target = WorkspaceListNewWorkspaceMenuValue.ComputerTarget(
            id: "cloud-1",
            kind: .cloud(hostID: "cloud-1"),
            name: "Cloud",
            isConnected: false,
            systemImage: "cloud"
        )
        let value = WorkspaceListNewWorkspaceMenuValue(
            canCreate: false,
            canCreateGroup: false,
            computerTargets: [target]
        )

        #expect(!value.isEnabled)
        #expect(value.singleConnectedTarget == nil)
    }
}
