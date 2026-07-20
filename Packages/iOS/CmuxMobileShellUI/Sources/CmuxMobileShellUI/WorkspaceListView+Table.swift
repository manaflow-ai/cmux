#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

extension WorkspaceListView {
    var showsWorkspaceTableFilterEmptyRow: Bool {
        activeFilter.isActive
            && trimmedQuery.isEmpty
            && filteredWorkspaces.isEmpty
            && !workspaces.isEmpty
    }

    var workspaceTableItems: [WorkspaceListTableItem] {
        var items: [WorkspaceListTableItem] = []
        switch connectionChrome {
        case .recoveryBanner:
            items.append(.chrome(.recoveryBanner))
        case .macStatusRow:
            items.append(.chrome(.macStatusRow))
        case .none:
            break
        }

        if rendersGroupedSections {
            items.append(contentsOf: displayedGroupedListItems.map { item in
                switch item {
                case .groupHeader(let group, _):
                    .groupHeader(group.id)
                case .groupFooter(let groupID):
                    .groupFooter(groupID)
                case .workspace(let workspace, let indented):
                    .workspace(workspace.id, indented: indented)
                }
            })
        } else if showsWorkspaceTableFilterEmptyRow {
            items.append(.filterEmpty)
        } else {
            items.append(contentsOf: displayedFlatWorkspaces.map {
                .workspace($0.id, indented: false)
            })
        }
        return items
    }

    var workspaceTableGroupHasUnreadByID: [MobileWorkspaceGroupPreview.ID: Bool] {
        var result: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        for item in displayedGroupedListItems {
            if case .groupHeader(let group, let hasUnread) = item {
                result[group.id] = hasUnread
            }
        }
        return result
    }

    var workspaceTable: WorkspaceListTable {
        let grouped = rendersGroupedSections
        let enablesReorder = enablesWorkspaceReorder
        return WorkspaceListTable(
            items: workspaceTableItems,
            workspacesByID: Dictionary(
                workspaces.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            groupsByID: groupsByID,
            groupHasUnreadByID: workspaceTableGroupHasUnreadByID,
            filter: activeFilter,
            selectedWorkspaceID: selectedWorkspaceID,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            profilePictureLeftShift: profilePictureLeftShift,
            profilePictureSize: profilePictureSize,
            connectionStatus: connectionStatus,
            connectionRequiresReauth: store?.connectionRequiresReauth ?? false,
            connectionRecoveryFailed: store?.connectionRecoveryFailed ?? false,
            isRecoveringConnection: store?.isRecoveringConnection ?? false,
            connectionError: store?.connectionError,
            host: host,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTitle: initialConnectionTimedOut
                ? L10n.string("mobile.loading.timeout.title", defaultValue: "Still loading")
                : nil,
            initialConnectionDescription: initialConnectionTimedOut
                ? L10n.string(
                    "mobile.loading.timeout.message",
                    defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry or add this computer again."
                )
                : nil,
            enablesReorder: enablesReorder,
            moveRows: enablesReorder ? { sourceOffsets, destination in
                if grouped {
                    moveGroupedRows(from: sourceOffsets, to: destination)
                } else {
                    moveFlatRows(from: sourceOffsets, to: destination)
                }
            } : nil,
            selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
            requestWorkspaceClose: requestWorkspaceClose,
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: requestWorkspaceRename,
            createWorkspaceInGroup: canCreateWorkspaceInGroups ? createWorkspaceInGroup : nil,
            renameWorkspaceGroup: renameWorkspaceGroup,
            setGroupPinned: setGroupPinned,
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            toggleGroupCollapsed: toggleGroupCollapsed,
            showAll: {
                filter = .all
                macSelection = .all
            },
            retryConnectionRecovery: store.map { store in
                { store.retryMobileConnection() }
            },
            signOut: signOut,
            retryInitialConnection: initialConnectionTimedOut ? retryInitialConnection : nil,
            showAddDevice: initialConnectionTimedOut ? showAddDevice : nil,
            reconnect: reconnect,
            refresh: refresh
        )
    }
}
#endif
