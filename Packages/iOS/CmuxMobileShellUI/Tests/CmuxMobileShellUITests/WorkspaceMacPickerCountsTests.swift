import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceMacPickerCountsTests {
    @Test func countsSplitSiblingBuildsByPairingAndKeepUntaggedRowsOutOfBuildScopes() {
        let nightly = pairedMac(deviceID: "mac-a", name: "Desk Mac", instanceTag: "nightly", isActive: true)
        let stable = pairedMac(deviceID: "mac-a", name: "Desk Mac", instanceTag: "stable")
        let workspaces = [
            workspace("n1", macDeviceID: "mac-a", tag: "nightly"),
            workspace("n2", macDeviceID: "mac-a", tag: "nightly"),
            workspace("s1", macDeviceID: "mac-a", tag: "stable"),
            workspace("legacy", macDeviceID: "mac-a", tag: nil),
            workspace("b1", macDeviceID: "mac-b", tag: nil),
        ]
        let scope = selectionScope(workspaces: workspaces, pairedMacs: [nightly, stable])

        let counts = scope.macPickerCounts(base: .all)

        #expect(counts.all == 5)
        // A tagged pairing row counts only rows proven to be that build; the
        // untagged legacy row stays out of both sibling scopes.
        #expect(counts.count(for: nightly.id) == 2)
        #expect(counts.count(for: stable.id) == 1)
        // A workspace-only device entry counts every row on that device.
        #expect(counts.count(for: "mac-b") == 1)
    }

    @Test func everyRowCountEqualsTheListItsSelectionShows() {
        let nightly = pairedMac(deviceID: "mac-a", name: "Desk Mac", instanceTag: "nightly", isActive: true)
        let stable = pairedMac(deviceID: "mac-a", name: "Desk Mac", instanceTag: "stable")
        let workspaces = [
            workspace("n1", macDeviceID: "mac-a", tag: "nightly", hasUnread: true),
            workspace("s1", macDeviceID: "mac-a", tag: "stable"),
            workspace("legacy", macDeviceID: "mac-a", tag: nil, hasUnread: true),
            workspace("b1", macDeviceID: "mac-b", tag: nil),
            workspace("orphan", macDeviceID: nil, tag: nil),
        ]
        for base in [MobileWorkspaceListFilter.all, MobileWorkspaceListFilter(readState: .unread)] {
            let scope = selectionScope(workspaces: workspaces, pairedMacs: [nightly, stable])
            let counts = scope.macPickerCounts(base: base)

            let allScope = selectionScope(
                selection: .all, workspaces: workspaces, pairedMacs: [nightly, stable]
            )
            let shownForAll = workspaces.filter(allScope.activeFilter(base: base).matches)
            #expect(counts.all == shownForAll.count)

            for id in scope.machineIDs {
                let rowScope = selectionScope(
                    selection: .machine(id), workspaces: workspaces, pairedMacs: [nightly, stable]
                )
                let shown = workspaces.filter(rowScope.activeFilter(base: base).matches)
                #expect(counts.count(for: id) == shown.count, "row \(id) base \(base)")
            }
        }
    }

    @Test func unreadBaseFilterNarrowsEveryCount() {
        let workspaces = [
            workspace("a1", macDeviceID: "mac-a", tag: nil, hasUnread: true),
            workspace("a2", macDeviceID: "mac-a", tag: nil),
            workspace("b1", macDeviceID: "mac-b", tag: nil),
        ]
        let scope = selectionScope(workspaces: workspaces, pairedMacs: [])

        let counts = scope.macPickerCounts(base: MobileWorkspaceListFilter(readState: .unread))

        #expect(counts.all == 1)
        #expect(counts.count(for: "mac-a") == 1)
        #expect(counts.count(for: "mac-b") == 0)
    }

    @Test func snapshotsStampCountsOnPickerRowsAndAllCount() {
        let solo = pairedMac(deviceID: "mac-idle", name: "Idle Mac", instanceTag: "stable")
        let workspaces = [
            workspace("a1", macDeviceID: "mac-a", tag: nil),
            workspace("a2", macDeviceID: "mac-a", tag: nil),
        ]
        let scope = selectionScope(workspaces: workspaces, pairedMacs: [solo])
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: workspaces,
            filterMachineIDFor: { scope.aliasIndex.deviceRepresentativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: ["mac-a": "Busy Mac", solo.id: solo.resolvedName],
            fallbackName: "Mac",
            pickerCounts: scope.macPickerCounts(base: .all)
        )

        #expect(snapshots.allWorkspaceCount == 2)
        let countsByID = Dictionary(
            uniqueKeysWithValues: snapshots.macPickerMachines.map { ($0.id, $0.workspaceCount) }
        )
        #expect(countsByID["mac-a"] == 2)
        // A paired Mac with no rows stamps an explicit zero, not a missing count.
        #expect(countsByID[solo.id] == 0)
    }

    @Test func snapshotsWithoutCountsLeaveRowsUnstamped() {
        let snapshots = WorkspaceMachineSnapshots(
            workspaces: [workspace("a1", macDeviceID: "mac-a", tag: nil)],
            macPickerMachineIDs: ["mac-a"],
            namesByID: ["mac-a": "Busy Mac"],
            fallbackName: "Mac"
        )

        #expect(snapshots.allWorkspaceCount == nil)
        #expect(snapshots.macPickerMachines.allSatisfy { $0.workspaceCount == nil })
    }

    @Test func rowSubtitleJoinsBuildLabelAndCount() {
        #expect(WorkspaceMacTitlePicker.rowSubtitle(buildLabel: nil, workspaceCount: nil) == nil)
        #expect(WorkspaceMacTitlePicker.rowSubtitle(buildLabel: "Nightly", workspaceCount: nil) == "Nightly")
        #expect(WorkspaceMacTitlePicker.rowSubtitle(buildLabel: nil, workspaceCount: 3) == "3 workspaces")
        #expect(WorkspaceMacTitlePicker.rowSubtitle(buildLabel: nil, workspaceCount: 1) == "1 workspace")
        #expect(
            WorkspaceMacTitlePicker.rowSubtitle(buildLabel: "Nightly", workspaceCount: 3)
                == "Nightly · 3 workspaces"
        )
        #expect(WorkspaceMacTitlePicker.rowSubtitle(buildLabel: nil, workspaceCount: 0) == "0 workspaces")
    }

    private func workspace(
        _ id: String,
        macDeviceID: String?,
        tag: String?,
        hasUnread: Bool = false
    ) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: "Workspace \(id)",
            hasUnread: hasUnread,
            terminals: []
        )
        preview.macInstanceTag = tag
        return preview
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
        selection: WorkspaceMacSelection = .all,
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
