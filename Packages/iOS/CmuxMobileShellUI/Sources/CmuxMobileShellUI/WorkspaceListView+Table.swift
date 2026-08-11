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

    func workspaceTableItems(
        groupedItems: [MobileWorkspaceListItem]
    ) -> [WorkspaceListTableItem] {
        var items: [WorkspaceListTableItem] = []
        switch connectionChrome {
        case .recoveryBanner:
            items.append(.chrome(.recoveryBanner))
        case .macStatusRow:
            items.append(.chrome(.macStatusRow))
        case .statusLine, .none:
            // The status line renders under the computers picker in the
            // toolbar, not as a list row; content stays uncovered.
            break
        }

        if rendersGroupedSections {
            items.append(contentsOf: groupedItems.map { item in
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

    func workspaceTableGroupHasUnreadByID(
        groupedItems: [MobileWorkspaceListItem]
    ) -> [MobileWorkspaceGroupPreview.ID: Bool] {
        var result: [MobileWorkspaceGroupPreview.ID: Bool] = [:]
        for item in groupedItems {
            if case .groupHeader(let group, let hasUnread) = item {
                result[group.id] = hasUnread
            }
        }
        return result
    }

    func workspaceTable(
        groupedItems: [MobileWorkspaceListItem],
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> WorkspaceListTable {
        let grouped = rendersGroupedSections
        let enablesReorder = enablesWorkspaceReorder
        // Bound outside the member-wise init: the ternary between `nil` and a
        // closure literal inside this large expression overwhelms the type
        // checker ("failed to produce diagnostic").
        let openChanges: (@MainActor (MobileWorkspacePreview) -> Void)? =
            store == nil
                ? nil
                : { @MainActor workspace in
                    openWorkspaceChanges(workspace)
                }
        return WorkspaceListTable(
            items: workspaceTableItems(groupedItems: groupedItems),
            workspacesByID: workspacesByID,
            groupsByID: groupsByID,
            groupHasUnreadByID: workspaceTableGroupHasUnreadByID(
                groupedItems: groupedItems
            ),
            filter: activeFilter,
            selectedWorkspaceID: selectedWorkspaceID,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            connectionStatus: connectionStatus,
            workspaceChangesCapable: workspaceChangesCapable,
            workspaceChangeChipsByWorkspaceID: workspaceChangeChipsByWorkspaceID,
            openWorkspaceChanges: openChanges,
            connectionRequiresReauth: store?.connectionRequiresReauth ?? false,
            connectionError: store?.connectionError,
            host: host,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTitle: initialConnectionTimedOut
                ? L10n.string("mobile.loading.timeout.title", defaultValue: "Still loading")
                : nil,
            initialConnectionDescription: initialConnectionTimedOut
                ? L10n.string(
                    "mobile.loading.timeout.message",
                    defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry."
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
            canDropIntoGroup: enablesReorder && grouped ? { workspaceID, groupID in
                canJoinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            dropIntoGroup: enablesReorder && grouped ? { workspaceID, groupID in
                joinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            groupMoveMenu: enablesReorder && grouped ? { workspaceID in
                groupMoveMenu(for: workspaceID)
            } : nil,
            moveToGroup: enablesReorder && grouped ? { workspaceID, groupID in
                joinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: requestWorkspaceRename,
            customizeRequest: requestWorkspaceCustomization,
            createWorkspaceInGroup: canCreateWorkspaceInGroups ? createWorkspaceInGroup : nil,
            renameWorkspaceGroup: renameWorkspaceGroup,
            renameWorkspaceGroupRequest: requestWorkspaceGroupRename,
            setGroupPinned: setGroupPinned,
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            ungroupWorkspaceGroupRequest: requestWorkspaceGroupUngroup,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            deleteWorkspaceGroupRequest: requestWorkspaceGroupDelete,
            toggleGroupCollapsed: toggleGroupCollapsed,
            showAll: {
                filter = .all
                macSelection = .all
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
