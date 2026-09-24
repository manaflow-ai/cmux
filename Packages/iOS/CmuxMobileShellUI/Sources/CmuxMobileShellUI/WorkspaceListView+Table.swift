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
            if groupedItems.isEmpty
                && trimmedQuery.isEmpty
                && !activeFilter.isActive
                && workspaces.isEmpty {
                items.append(.emptyWorkspaceList)
            } else {
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
            }
        } else if showsWorkspaceTableFilterEmptyRow {
            items.append(.filterEmpty)
        } else if trimmedQuery.isEmpty
            && !activeFilter.isActive
            && workspaces.isEmpty {
            items.append(.emptyWorkspaceList)
        } else {
            items.append(contentsOf: displayedFlatWorkspaces.map {
                .workspace($0.id, indented: false)
            })
        }
        return items
    }

    func workspaceTableGroupUnreadByID(
        groupedItems: [MobileWorkspaceListItem]
    ) -> [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] {
        var result: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] = [:]
        for item in groupedItems {
            if case .groupHeader(let group, let unread) = item {
                result[group.id] = unread
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
        let movePresentedRows: (([WorkspaceListTableItem], IndexSet, Int) -> Void)?
        if enablesReorder {
            movePresentedRows = { presentedItems, sourceOffsets, destination in
                if grouped {
                    let itemsByID = Dictionary(uniqueKeysWithValues: groupedItems.map { item in
                        let id: String
                        if case .groupHeader(let group, _) = item {
                            id = "groupHeader.\(group.id.rawValue)"
                        } else {
                            id = item.id
                        }
                        return (id, item)
                    })
                    moveGroupedRows(
                        from: sourceOffsets,
                        to: destination,
                        presentedItems: presentedItems.compactMap { itemsByID[$0.id] }
                    )
                } else {
                    moveFlatRows(
                        from: sourceOffsets,
                        to: destination,
                        presentedWorkspaces: presentedItems.compactMap { item in
                            item.workspaceID.flatMap { workspacesByID[$0] }
                        }
                    )
                }
            }
        } else {
            movePresentedRows = nil
        }
        let emptyStateRecoveryTarget = store?.workspaceListRecoveryTarget
        let emptyStateMacDeviceID = emptyStateRecoveryTarget?.macDeviceID
        let emptyStateMacInstanceTag = emptyStateRecoveryTarget?.instanceTag
        let isRetryOwnerCurrentOnDisappear: (() -> Bool)? = store.map { store in
            {
                let currentTarget = store.workspaceListRecoveryTarget
                if store.isRecoveringWorkspaceList {
                    return store.isWorkspaceListRecoveryOwned(
                        byMacDeviceID: emptyStateMacDeviceID,
                        instanceTag: emptyStateMacInstanceTag
                    )
                        && currentTarget?.macDeviceID == emptyStateMacDeviceID
                        && currentTarget?.instanceTag == emptyStateMacInstanceTag
                }
                return currentTarget?.macDeviceID == emptyStateMacDeviceID
                    && currentTarget?.instanceTag == emptyStateMacInstanceTag
            }
        }
        let shouldCancelRefreshOnDisappear: (() -> Bool)? = store.map { store in
            {
                let currentTarget = store.workspaceListRecoveryTarget
                return currentTarget?.macDeviceID == emptyStateMacDeviceID
                    && currentTarget?.instanceTag == emptyStateMacInstanceTag
                    && store.workspaces.isEmpty
                    // Hiding the empty row is itself part of the active
                    // recovery transition. Do not let that structural
                    // disappearance cancel the retry that owns recovery.
                    && !store.isRecoveringWorkspaceList
            }
        }
        let cancelRefreshForEmptyState: (() -> Void)? = store.map { store in
            {
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    ownerScoped: true
                )
            }
        } ?? cancelRefresh
        let cancelRefreshOnDisappearForEmptyState: (() -> Void)? = store.map { store in
            {
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    ownerScoped: true
                )
            }
        }
        let beginRefreshForEmptyState: (() -> UUID?)? = store.map { store in
            {
                store.prepareWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag
                )
            }
        }
        let cancelRefreshAttemptForEmptyState: ((UUID?) -> Void)? = store.map { store in
            { generation in
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    expectedGeneration: generation,
                    ownerScoped: true
                )
            }
        } ?? cancelRefresh.map { suppliedCancel in
            { _ in suppliedCancel() }
        }
        return WorkspaceListTable(
            items: workspaceTableItems(groupedItems: groupedItems),
            preservesItemOrderDuringLiveUpdates: pendingWorkspaceMoveCount == 0,
            presentationOrderIdentity: workspaceTablePresentationOrderIdentity,
            workspacesByID: workspacesByID,
            groupsByID: groupsByID,
            groupUnreadByID: workspaceTableGroupUnreadByID(
                groupedItems: groupedItems
            ),
            filter: activeFilter,
            selectedWorkspaceID: selectedWorkspaceID,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            unreadBadgeDiameter: unreadBadgeDiameter,
            connectionStatus: connectionStatus,
            workspaceOwnerID: emptyStateMacDeviceID,
            workspaceOwnerInstanceTag: emptyStateMacInstanceTag,
            showsWorkspaceEmptyState: connectionChrome.showsWorkspaceEmptyState,
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
            moveRows: movePresentedRows,
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
            refresh: refresh,
            cancelRefresh: cancelRefreshForEmptyState,
            cancelRefreshOnDisappear: cancelRefreshOnDisappearForEmptyState,
            beginRefresh: beginRefreshForEmptyState,
            cancelRefreshAttempt: cancelRefreshAttemptForEmptyState,
            cancelRefreshAttemptOnDisappear: cancelRefreshAttemptForEmptyState,
            shouldCancelRefreshOnDisappear: shouldCancelRefreshOnDisappear,
            isRetryOwnerCurrentOnDisappear: isRetryOwnerCurrentOnDisappear
        )
    }

    /// The table owns its displayed order while this presentation is alive.
    /// The Mac can reorder its source array on every notification, even when
    /// iOS uses Automatic sorting. Compare membership and grouping without
    /// source order so those updates cannot rearrange rows under the reader.
    /// Sort/scope choices, pinning, and grouping still reset the presentation;
    /// local drag/drop updates the table's order directly.
    private var workspaceTablePresentationOrderIdentity: [String] {
        var identity = workspaces.map { workspace in
            [
                "workspace",
                workspace.id.rawValue,
                workspace.groupID?.rawValue ?? "",
                workspace.macDeviceID ?? "",
                workspace.macInstanceTag ?? "",
                String(workspace.isPinned),
            ].joined(separator: "\u{1F}")
        }
        identity.append(contentsOf: groups.map { group in
            [
                "group",
                group.id.rawValue,
                group.anchorWorkspaceID.rawValue,
                group.macDeviceID ?? "",
                group.macInstanceTag ?? "",
                String(group.isPinned),
                String(group.isCollapsed),
                String(group.isEmpty),
            ].joined(separator: "\u{1F}")
        })
        let scope: String
        switch visibleMacSelection {
        case .all: scope = "all"
        case .automatic: scope = "automatic"
        case .machine(let id): scope = "machine:\(id)"
        }
        return [
            "sort:\(workspaceSortMode.rawValue)",
            "scope:\(scope)",
            "moveEpoch:\(workspaceMoveEpoch)",
        ]
            + workspaceComputerPriority.map { "priority:\($0)" }
            + identity.sorted()
    }
}
#endif
