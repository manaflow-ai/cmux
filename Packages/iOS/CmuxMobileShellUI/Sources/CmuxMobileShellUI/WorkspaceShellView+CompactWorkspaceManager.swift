import SwiftUI

extension WorkspaceShellView {
    /// The existing workspace list presented from the compact surface grid for
    /// rename, pin, move, and group organization actions.
    var compactWorkspaceManager: some View {
        WorkspaceListView(
            workspaces: store.workspaces,
            groups: store.workspaceGroups,
            selectedWorkspaceID: store.selectedWorkspaceID,
            host: store.connectedHostName,
            connectionStatus: listConnectionStatus,
            navigationStyle: .sidebar,
            showsNavigationToolbar: false,
            wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
            previewLineLimit: displaySettings.workspacePreviewLineCount,
            unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
            profilePictureLeftShift: displaySettings.profilePictureLeftShift,
            profilePictureSize: displaySettings.profilePictureSize,
            selectWorkspace: selectWorkspaceFromSurfaceGrid,
            createWorkspace: createWorkspaceInCompactStack,
            createWorkspaceInGroup: createWorkspaceInGroupInCompactStackClosure,
            createWorkspaceGroup: createWorkspaceGroupInCompactStackClosure,
            canCreateWorkspace: canCreateWorkspaceForMacSelection,
            macSelection: $macSelection,
            switchMac: { macDeviceID in
                await switchMacFromWorkspacePicker(macDeviceID: macDeviceID)
            },
            cancelMacSwitch: cancelMacSwitchFromWorkspacePicker,
            refresh: refreshWorkspacesClosure,
            reconnect: reconnectClosure,
            showAddDevice: showAddDevice,
            store: store,
            renameWorkspace: renameWorkspaceClosure,
            setPinned: setWorkspacePinnedClosure,
            setUnread: setWorkspaceUnreadClosure,
            closeWorkspace: closeWorkspaceClosure,
            moveWorkspace: moveWorkspaceClosure,
            renameWorkspaceGroup: renameWorkspaceGroupClosure,
            setGroupPinned: setWorkspaceGroupPinnedClosure,
            ungroupWorkspaceGroup: ungroupWorkspaceGroupClosure,
            deleteWorkspaceGroup: deleteWorkspaceGroupClosure,
            toggleGroupCollapsed: toggleGroupCollapsedClosure,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTimedOut: initialConnectionTimedOut,
            retryInitialConnection: retryInitialConnection
        )
    }
}
