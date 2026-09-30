import CmuxMobileShellModel
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceGroupDestructiveActionTests {
    @Test @MainActor func confirmUngroupRoutesOnlyUngroupAndClearsPendingState() {
        let groupID: MobileWorkspaceGroupPreview.ID = "group"
        var ungroupedGroupID: MobileWorkspaceGroupPreview.ID?
        var deletedGroupID: MobileWorkspaceGroupPreview.ID?
        let view = workspaceList(
            ungroupWorkspaceGroup: { ungroupedGroupID = $0 },
            deleteWorkspaceGroup: { deletedGroupID = $0 }
        )
        view.workspaceGroupDestructiveRequest.enqueue(groupID: groupID, action: .ungroup)

        view.confirmWorkspaceGroupDestructiveAction()

        #expect(ungroupedGroupID == groupID)
        #expect(deletedGroupID == nil)
        #expect(view.workspaceGroupPendingDestructiveID == nil)
        #expect(view.workspaceGroupPendingDestructiveAction == nil)
    }

    @Test @MainActor func confirmDeleteRoutesOnlyDeleteAndClearsPendingState() {
        let groupID: MobileWorkspaceGroupPreview.ID = "group"
        var ungroupedGroupID: MobileWorkspaceGroupPreview.ID?
        var deletedGroupID: MobileWorkspaceGroupPreview.ID?
        let view = workspaceList(
            ungroupWorkspaceGroup: { ungroupedGroupID = $0 },
            deleteWorkspaceGroup: { deletedGroupID = $0 }
        )
        view.workspaceGroupDestructiveRequest.enqueue(groupID: groupID, action: .delete)

        view.confirmWorkspaceGroupDestructiveAction()

        #expect(ungroupedGroupID == nil)
        #expect(deletedGroupID == groupID)
        #expect(view.workspaceGroupPendingDestructiveID == nil)
        #expect(view.workspaceGroupPendingDestructiveAction == nil)
    }

    @Test @MainActor func clearResetsPendingGroupAndAction() {
        let view = workspaceList()
        view.workspaceGroupDestructiveRequest.enqueue(groupID: "group", action: .delete)

        view.clearWorkspaceGroupDestructiveRequest()

        #expect(view.workspaceGroupPendingDestructiveID == nil)
        #expect(view.workspaceGroupPendingDestructiveAction == nil)
    }

    @MainActor private func workspaceList(
        ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    ) -> WorkspaceListView {
        WorkspaceListView(
            workspaces: [],
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .connected,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: .constant(.all),
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            filterState: WorkspaceListFilterState()
        )
    }
}
