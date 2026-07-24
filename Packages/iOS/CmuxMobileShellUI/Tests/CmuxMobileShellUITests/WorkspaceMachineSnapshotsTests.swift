import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceMachineSnapshotsTests {
    @Test func filterMachinesAreStableAcrossEquivalentWorkspaceChurn() {
        let first = machineSnapshots(workspaces: [
            workspace("recent-b", macDeviceID: "mac-b", macDisplayName: "Beta", hasUnread: true),
            workspace("older-a", macDeviceID: "mac-a", macDisplayName: "Alpha", hasUnread: false),
            workspace("recent-c", macDeviceID: "mac-c", macDisplayName: "Alpha", hasUnread: true),
        ])
        let second = machineSnapshots(workspaces: [
            workspace("new-c", macDeviceID: "mac-c", macDisplayName: "Alpha", hasUnread: false),
            workspace("new-a", macDeviceID: "mac-a", macDisplayName: "Alpha", hasUnread: true),
            workspace("new-b", macDeviceID: "mac-b", macDisplayName: "Beta", hasUnread: false),
        ])

        #expect(first.filterMachines == second.filterMachines)
        #expect(first.filterMachines.map(\.id) == ["mac-a", "mac-c", "mac-b"])
        #expect(first.filterMachines.map(\.name) == ["Alpha", "Alpha", "Beta"])
    }

    @Test func filterMachinesHideSingleMachineSection() {
        let snapshots = machineSnapshots(workspaces: [
            workspace("only-a", macDeviceID: "mac-a", macDisplayName: "Alpha", hasUnread: false),
            workspace("also-a", macDeviceID: "mac-a", macDisplayName: "Alpha", hasUnread: true),
        ])

        #expect(snapshots.filterMachines.isEmpty)
    }

    @Test func macPickerMachinesUseStableDisplaySortForSetInput() {
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: [],
            macPickerMachineIDs: ["mac-z", "mac-a", "mac-b"],
            namesByID: [
                "mac-a": "Studio",
                "mac-b": "Air",
                "mac-z": "Air",
            ],
            fallbackName: "Mac"
        )

        #expect(snapshots.macPickerMachines.map(\.id) == ["mac-b", "mac-z", "mac-a"])
        #expect(snapshots.macPickerMachines.map(\.name) == ["Air", "Air", "Studio"])
    }

    private func machineSnapshots(workspaces: [MobileWorkspacePreview]) -> WorkspaceMachineSnapshots {
        var namesByID: [String: String] = [:]
        for workspace in workspaces {
            if let macDeviceID = workspace.macDeviceID, let macDisplayName = workspace.macDisplayName {
                namesByID[macDeviceID] = macDisplayName
            }
        }
        return WorkspaceMachineSnapshots(
            workspaces: workspaces,
            macPickerMachineIDs: [],
            namesByID: namesByID,
            fallbackName: "Mac"
        )
    }

    private func workspace(
        _ id: String,
        macDeviceID: String,
        macDisplayName: String,
        hasUnread: Bool
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            name: "Workspace \(id)",
            hasUnread: hasUnread,
            terminals: []
        )
    }
}
