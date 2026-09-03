import CmuxWorkspaces
import Foundation
import Testing

@Suite("Terminal session restore planner")
struct TerminalSessionRestorePlannerTests {
    @Test
    func filtersWorkspacesAndRemapsSelectionAndGroupAnchor() {
        let groupID = UUID()
        let terminalID = UUID()
        let browserID = UUID()
        let planner = TerminalSessionRestorePlanner(restoreTerminalSessions: false)
        let result = planner.planWorkspaces(
            [
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: terminalID,
                    groupID: groupID,
                    containsTerminalSurface: true
                ),
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: browserID,
                    groupID: groupID,
                    containsTerminalSurface: false
                ),
            ],
            selectedWorkspaceIndex: 0,
            groups: [
                TerminalSessionRestoreGroupDescriptor(
                    id: groupID,
                    anchorMemberIndex: 1,
                    anchorWorkspaceID: browserID
                )
            ]
        )

        #expect(result.retainedOriginalOffsets == [1])
        #expect(result.selectedWorkspaceIndex == nil)
        #expect(result.groups == [
            TerminalSessionRestoreGroupPlan(
                id: groupID,
                anchorMemberIndex: 0,
                anchorWorkspaceID: browserID
            )
        ])
    }

    @Test
    func restoreEnabledRetainsEveryWorkspace() {
        let planner = TerminalSessionRestorePlanner(restoreTerminalSessions: true)
        let result = planner.planWorkspaces(
            [
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: UUID(),
                    groupID: nil,
                    containsTerminalSurface: true
                ),
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: UUID(),
                    groupID: nil,
                    containsTerminalSurface: false
                ),
            ],
            selectedWorkspaceIndex: 1,
            groups: nil
        )

        #expect(result.retainedOriginalOffsets == [0, 1])
        #expect(result.selectedWorkspaceIndex == 1)
    }

    @Test
    func preservesPinnedEmptyGroupsWithoutWorkspaceMembers() {
        let groupID = UUID()
        let planner = TerminalSessionRestorePlanner(restoreTerminalSessions: false)
        let result = planner.planWorkspaces(
            [],
            selectedWorkspaceIndex: nil,
            groups: [
                TerminalSessionRestoreGroupDescriptor(
                    id: groupID,
                    anchorMemberIndex: nil,
                    anchorWorkspaceID: groupID,
                    preserveWhenEmpty: true
                )
            ]
        )

        #expect(result.retainedOriginalOffsets.isEmpty)
        #expect(result.groups == [
            TerminalSessionRestoreGroupPlan(
                id: groupID,
                anchorMemberIndex: nil,
                anchorWorkspaceID: nil
            )
        ])
    }

    @Test
    func preservesPinnedGroupWhenEveryMemberIsFiltered() {
        let groupID = UUID()
        let planner = TerminalSessionRestorePlanner(restoreTerminalSessions: false)
        let result = planner.planWorkspaces(
            [
                TerminalSessionRestoreWorkspaceDescriptor(
                    workspaceID: UUID(),
                    groupID: groupID,
                    containsTerminalSurface: true
                )
            ],
            selectedWorkspaceIndex: 0,
            groups: [
                TerminalSessionRestoreGroupDescriptor(
                    id: groupID,
                    anchorMemberIndex: 0,
                    anchorWorkspaceID: nil,
                    preserveWhenEmpty: true
                )
            ]
        )

        #expect(result.retainedOriginalOffsets.isEmpty)
        #expect(result.groups?.first?.anchorMemberIndex == nil)
        #expect(result.groups?.first?.anchorWorkspaceID == nil)
    }

    @Test
    func filtersContainerPanelsAndCollapsesEmptySplitBranches() {
        let terminalID = UUID()
        let browserID = UUID()
        let planner = TerminalSessionRestorePlanner(restoreTerminalSessions: false)
        let result = planner.planContainer(
            panels: [
                TerminalSessionRestorePanelDescriptor(
                    id: terminalID,
                    containsTerminalSurface: true
                ),
                TerminalSessionRestorePanelDescriptor(
                    id: browserID,
                    containsTerminalSurface: false
                ),
            ],
            focusedPanelID: terminalID,
            layout: .split(
                orientation: .horizontal,
                dividerPosition: 0.5,
                first: .pane(
                    panelIDs: [terminalID],
                    selectedPanelID: terminalID,
                    isFullWidthTabMode: nil
                ),
                second: .pane(
                    panelIDs: [browserID],
                    selectedPanelID: browserID,
                    isFullWidthTabMode: nil
                )
            )
        )

        #expect(result?.retainedPanelIDs == [browserID])
        #expect(result?.focusedPanelID == browserID)
        #expect(result?.layout == .pane(
            panelIDs: [browserID],
            selectedPanelID: browserID,
            isFullWidthTabMode: nil
        ))
    }
}
