import Testing
import SwiftUI
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListNewWorkspaceMenuValueTests {
    @Test func loneConnectedCloudTargetRemainsAValidCreationTarget() {
        let target = WorkspaceCreateComputerTarget(
            id: "cloud-1",
            kind: .cloud(hostID: "cloud-1"),
            name: "Cloud",
            statusText: nil,
            statusColor: .green
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
        let target = WorkspaceCreateComputerTarget(
            id: "cloud-1",
            kind: .cloud(hostID: "cloud-1"),
            name: "Cloud",
            statusText: "Disconnected",
            statusColor: .secondary
        )
        let value = WorkspaceListNewWorkspaceMenuValue(
            canCreate: false,
            canCreateGroup: false,
            computerTargets: [target]
        )

        #expect(!value.isEnabled)
        #expect(value.singleConnectedTarget == nil)
    }

    @Test func scopedCloudCreationDoesNotAutoSelectAConnectedMac() {
        let mac = WorkspaceCreateComputerTarget(
            id: "mac-1",
            kind: .mac(macDeviceID: "mac-1", instanceTag: nil),
            name: "Mac",
            statusText: nil,
            statusColor: .green
        )

        #expect(
            WorkspaceListNewWorkspaceMenuValue.soleConnectedTarget(
                scopedExternalHostID: "cloud-1",
                targets: [mac]
            ) == nil
        )
    }

    @Test func primaryActionRoutesToTheOnlyConnectedComputer() {
        let target = WorkspaceCreateComputerTarget(
            id: "cloud-1",
            kind: .cloud(hostID: "cloud-1"),
            name: "Cloud",
            statusText: nil,
            statusColor: .green
        )
        let value = WorkspaceListNewWorkspaceMenuValue(
            canCreate: false,
            canCreateGroup: false,
            computerTargets: [target]
        )
        var genericActionCalled = false
        var selectedTarget: WorkspaceCreateComputerTarget?
        let actions = WorkspaceListNewWorkspaceMenuActions(
            createWorkspace: { genericActionCalled = true },
            createWorkspaceGroup: nil,
            createWorkspaceOnComputer: { target, _ in selectedTarget = target }
        )

        actions.performPrimaryAction(for: value)

        #expect(!genericActionCalled)
        #expect(selectedTarget == target)
    }

    @Test func selectedCloudHostIsPartOfMenuIdentity() {
        let first = WorkspaceListNewWorkspaceMenuValue(
            canCreate: true,
            canCreateGroup: false,
            scopedExternalHostID: "cloud-1"
        )
        let second = WorkspaceListNewWorkspaceMenuValue(
            canCreate: true,
            canCreateGroup: false,
            scopedExternalHostID: "cloud-2"
        )

        #expect(first != second)
    }
}
