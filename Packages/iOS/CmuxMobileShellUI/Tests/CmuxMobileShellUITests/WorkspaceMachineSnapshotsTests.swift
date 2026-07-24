import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceMachineSnapshotsTests {
    @Test func pairedBuildsProduceDistinctPickerEntriesWithoutWorkspaceDuplicate() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable"
        )
        let scope = selectionScope(
            selection: .all,
            workspaces: [workspace("workspace-a", macDeviceID: "mac-a", macDisplayName: "Desk Mac")],
            pairedMacs: [nightly, stable]
        )
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: scope.workspaces,
            filterMachineIDFor: { scope.aliasIndex.deviceRepresentativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: [
                nightly.id: nightly.resolvedName,
                stable.id: stable.resolvedName,
            ],
            buildLabelsByID: [
                nightly.id: "Nightly",
                stable.id: "Stable",
            ],
            fallbackName: "Mac"
        )

        #expect(snapshots.macPickerMachines.count == 2)
        #expect(Set(snapshots.macPickerMachines.map(\.id)) == [nightly.id, stable.id])
        #expect(Set(snapshots.macPickerMachines.map(\.macDeviceID)) == ["mac-a"])
        #expect(Set(snapshots.macPickerMachines.compactMap(\.buildLabel)) == ["Nightly", "Stable"])
        #expect(Set(snapshots.macPickerMachines.map(\.name)) == ["Desk Mac"])
    }

    @Test func unpairedWorkspaceProducesDeviceLevelPickerEntryWithoutBuildLabel() {
        let scope = selectionScope(
            selection: .all,
            workspaces: [workspace("workspace-only", macDeviceID: "unpaired", macDisplayName: "Remote Mac")],
            pairedMacs: []
        )
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: scope.workspaces,
            filterMachineIDFor: { scope.aliasIndex.deviceRepresentativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: ["unpaired": "Remote Mac"],
            buildLabelsByID: [:],
            fallbackName: "Mac"
        )

        #expect(snapshots.macPickerMachines == [
            WorkspaceFilterMachine(
                id: "unpaired",
                macDeviceID: "unpaired",
                instanceTag: nil,
                name: "Remote Mac",
                buildLabel: nil
            ),
        ])
    }

    @Test func selectionScopeKeepsExistingPairingAndFallsBackWhenItDisappears() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable"
        )

        let present = selectionScope(
            selection: .machine(stable.id),
            workspaces: [],
            pairedMacs: [nightly, stable]
        )
        let removed = selectionScope(
            selection: .machine(stable.id),
            workspaces: [],
            pairedMacs: [nightly]
        )

        #expect(present.visibleSelection == .machine(stable.id))
        #expect(removed.visibleSelection == .all)
    }

    @Test func pairingSelectionFiltersByEveryDeviceAlias() {
        let nightly = pairedMac(
            deviceID: "mac-new",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let scope = WorkspaceMacSelectionScope(
            selection: .machine(nightly.id),
            workspaces: [],
            displayPairedMacs: [nightly],
            foregroundMacDeviceID: nil,
            aliasesFor: { id in
                id == "mac-new" ? ["mac-new", "mac-old"] : [id]
            }
        )

        #expect(scope.activeFilter(base: .all).machines == ["mac-new", "mac-old"])
    }

    @Test func pairingAwareSwitchDecisionDistinguishesSiblingBuilds() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable"
        )
        let scope = selectionScope(
            selection: .all,
            workspaces: [workspace("unpaired-workspace", macDeviceID: "unpaired", macDisplayName: "Remote")],
            pairedMacs: [nightly, stable]
        )

        #expect(!scope.shouldSwitch(to: nightly.id))
        #expect(scope.shouldSwitch(to: stable.id))
        #expect(!scope.shouldSwitch(to: "unpaired"))
        #expect(scope.switchTarget(for: stable.id)?.macDeviceID == "mac-a")
        #expect(scope.switchTarget(for: stable.id)?.instanceTag == "stable")
    }

    @Test func filterMachinesRemainOnePerDeviceWithoutBuildLabels() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable"
        )
        let other = pairedMac(
            deviceID: "mac-b",
            name: "Laptop",
            instanceTag: "stable"
        )
        let workspaces = [
            workspace("nightly-workspace", macDeviceID: "mac-a", macDisplayName: "Desk Mac"),
            workspace("stable-workspace", macDeviceID: "mac-a", macDisplayName: "Desk Mac"),
            workspace("other-workspace", macDeviceID: "mac-b", macDisplayName: "Laptop"),
        ]
        let scope = selectionScope(
            selection: .all,
            workspaces: workspaces,
            pairedMacs: [nightly, stable, other]
        )
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: workspaces,
            filterMachineIDFor: { scope.aliasIndex.deviceRepresentativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: [
                nightly.id: nightly.resolvedName,
                stable.id: stable.resolvedName,
                other.id: other.resolvedName,
            ],
            buildLabelsByID: [
                nightly.id: "Nightly",
                stable.id: "Stable",
                other.id: "Stable",
            ],
            fallbackName: "Mac"
        )

        #expect(snapshots.filterMachines.count == 2)
        #expect(Set(snapshots.filterMachines.map(\.macDeviceID)) == ["mac-a", "mac-b"])
        #expect(snapshots.filterMachines.allSatisfy { $0.buildLabel == nil })
    }

    @Test func aliasIndexPrefersActivePairingThenDisplayOrder() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly"
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable",
            isActive: true
        )
        let activeIndex = WorkspaceMacPickerAliasIndex(
            displayPairedMacs: [nightly, stable],
            aliasesFor: { [$0] }
        )
        let orderedIndex = WorkspaceMacPickerAliasIndex(
            displayPairedMacs: [nightly, stable].map {
                var mac = $0
                mac.isActive = false
                return mac
            },
            aliasesFor: { [$0] }
        )

        #expect(activeIndex.representativeID(for: "mac-a") == stable.id)
        #expect(orderedIndex.representativeID(for: "mac-a") == nightly.id)
        #expect(activeIndex.representativeID(for: nightly.id) == nightly.id)
        #expect(activeIndex.representativeID(for: stable.id) == stable.id)
        #expect(activeIndex.filterMachineIDs(for: nightly.id) == ["mac-a"])
        #expect(activeIndex.filterMachineIDs(for: stable.id) == ["mac-a"])
    }

    @Test func composerMenuSelectsExactlyOnePairing() {
        let nightly = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "nightly",
            isActive: true
        )
        let stable = pairedMac(
            deviceID: "mac-a",
            name: "Desk Mac",
            instanceTag: "stable"
        )
        let value = TaskComposerMachineMenuValue(
            machines: [nightly, stable],
            selectedMacPairingID: stable.id,
            buildLabelsByID: [
                nightly.id: "Nightly",
                stable.id: "Stable",
            ],
            isDisabled: false
        )

        #expect(value.machines.filter(value.isSelected).map(\.id) == [stable.id])
    }

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
        hasUnread: Bool = false
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

    private func pairedMac(
        deviceID: String,
        name: String,
        instanceTag: String,
        isActive: Bool = false
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: deviceID,
            displayName: name,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0),
            isActive: isActive,
            stackUserID: "user-1",
            instanceTag: instanceTag
        )
    }

    private func selectionScope(
        selection: WorkspaceMacSelection,
        workspaces: [MobileWorkspacePreview],
        pairedMacs: [MobilePairedMac]
    ) -> WorkspaceMacSelectionScope {
        WorkspaceMacSelectionScope(
            selection: selection,
            workspaces: workspaces,
            displayPairedMacs: pairedMacs,
            foregroundMacDeviceID: nil,
            aliasesFor: { [$0] }
        )
    }
}
