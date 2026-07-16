import CmuxCore
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Immutable inputs used to assemble one workspace row when a lazy stack realizes it.
///
/// The sidebar owner resolves every live model read into this value before the
/// `LazyVStack`. Context-menu notifications and row-specific action closures
/// are intentionally assembled later so parent invalidations stay O(values),
/// not O(full row subtrees).
struct SidebarWorkspaceRowInput {
    let workspaceId: UUID
    let groupId: UUID?
    let index: Int
    let workspaceCount: Int
    let workspace: SidebarWorkspaceSnapshotBuilder.Snapshot
    let isActive: Bool
    let isMultiSelected: Bool
    let hasUserCustomTitle: Bool
    let hasCustomTitle: Bool
    let hasCustomDescription: Bool
    let customTitle: String?
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let unreadCount: Int
    let latestNotificationText: String?
    let showsAgentActivity: Bool
    let rowSpacing: CGFloat
    let showsModifierShortcutHints: Bool
    let isPointerHovering: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let isBonsplitWorkspaceDropActive: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let isChecklistExpanded: Bool
    let checklistAddFieldActivationToken: Int
    let isChecklistPopoverPresented: Bool
    let isRemoteContextMenuEligible: Bool
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let inferredTaskStatus: WorkspaceTaskStatus
    let activeTodoOverride: WorkspaceTaskStatus?
    let isTodoStatusHidden: Bool

    @MainActor
    func rowSnapshot(list: SidebarWorkspaceRowsSnapshot) -> SidebarWorkspaceRowSnapshot {
        let targetAggregate = list.contextMenuTargetAggregate(for: self)
        return SidebarWorkspaceRowSnapshot(
            workspaceId: workspaceId,
            groupId: groupId,
            index: index,
            workspaceCount: workspaceCount,
            workspace: workspace,
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            hasUserCustomTitle: hasUserCustomTitle,
            hasCustomTitle: hasCustomTitle,
            hasCustomDescription: hasCustomDescription,
            customTitle: customTitle,
            workspaceShortcutDigit: workspaceShortcutDigit,
            workspaceShortcutModifierSymbol: workspaceShortcutModifierSymbol,
            canCloseWorkspace: canCloseWorkspace,
            unreadCount: unreadCount,
            latestNotificationText: latestNotificationText,
            showsAgentActivity: showsAgentActivity,
            rowSpacing: rowSpacing,
            showsModifierShortcutHints: showsModifierShortcutHints,
            isPointerHovering: isPointerHovering,
            isBeingDragged: isBeingDragged,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropActive,
            settings: settings,
            isChecklistExpanded: isChecklistExpanded,
            checklistAddFieldActivationToken: checklistAddFieldActivationToken,
            isChecklistPopoverPresented: isChecklistPopoverPresented,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: targetAggregate.targetWorkspaceIds,
                remoteTargetWorkspaceIds: targetAggregate.remoteTargetWorkspaceIds,
                allRemoteTargetsConnecting: targetAggregate.allRemoteTargetsConnecting,
                allRemoteTargetsDisconnected: targetAggregate.allRemoteTargetsDisconnected,
                pinState: contextMenuPinState,
                groupMenuSnapshot: list.workspaceGroupMenuSnapshot,
                canCreateEmptyGroup: list.canCreateEmptyGroup,
                eligibleGroupTargetIds: targetAggregate.eligibleGroupTargetIds,
                allEligibleTargetsGroupId: targetAggregate.allEligibleTargetsGroupId,
                hasGroupedEligibleTarget: targetAggregate.hasGroupedEligibleTarget,
                todoStatusLanes: WorkspaceTodoStatusLane.lanes(
                    inferred: inferredTaskStatus,
                    activeOverride: activeTodoOverride,
                    isHidden: isTodoStatusHidden
                ),
                canMarkRead: targetAggregate.canMarkRead,
                canMarkUnread: targetAggregate.canMarkUnread,
                hasLatestNotification: targetAggregate.hasLatestNotification,
                notifications: targetAggregate.notifications
            )
        )
    }
}
