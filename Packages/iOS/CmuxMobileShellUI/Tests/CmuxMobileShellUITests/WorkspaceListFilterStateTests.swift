import CmuxMobileShellModel
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListFilterStateTests {
    @Test @MainActor func searchPresentationUsesTheNormalPresentationFilter() {
        let readWorkspace = MobileWorkspacePreview(
            id: "read",
            macDeviceID: "mac",
            name: "Read",
            hasUnread: false,
            terminals: []
        )
        let unreadWorkspace = MobileWorkspacePreview(
            id: "unread",
            macDeviceID: "mac",
            name: "Unread",
            hasUnread: true,
            terminals: []
        )
        let filterState = WorkspaceListFilterState()
        let normalPresentation = workspaceList(
            workspaces: [readWorkspace, unreadWorkspace],
            searchText: "",
            filterState: filterState
        )
        let searchPresentation = workspaceList(
            workspaces: [readWorkspace, unreadWorkspace],
            searchText: "read",
            filterState: filterState
        )

        filterState.filter.readState = .unread

        #expect(normalPresentation.filteredWorkspaces.map(\.id) == [unreadWorkspace.id])
        #expect(searchPresentation.filteredWorkspaces.map(\.id) == [unreadWorkspace.id])
    }

    @MainActor private func workspaceList(
        workspaces: [MobileWorkspacePreview],
        searchText: String,
        filterState: WorkspaceListFilterState
    ) -> WorkspaceListView {
        WorkspaceListView(
            workspaces: workspaces,
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .connected,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: .constant(.all),
            filterState: filterState,
            searchText: searchText
        )
    }
}
