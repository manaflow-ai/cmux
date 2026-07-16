import CmuxFoundation
import CmuxSidebar
import Foundation

/// Value-only resolver for complete sidebar row inputs.
///
/// The parent creates one projection before `LazyVStack`; SwiftUI invokes
/// `input(for:)` only for realized rows. All expensive workspace presentation
/// snapshots were already built by the parent's observation callbacks, so this
/// resolver performs no model reads, state writes, or snapshot construction.
struct SidebarWorkspaceRowInputProjection {
    let modelSnapshotsById: [UUID: SidebarWorkspaceRowModelSnapshot]
    let workspaceSnapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot]
    let unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    let tabIndexById: [UUID: Int]
    let selectedContextTargetIds: [UUID]
    let selectedWorkspaceIds: Set<UUID>
    let activeWorkspaceId: UUID?
    let hoveredRowId: SidebarWorkspaceRenderItemID?
    let draggedWorkspaceId: UUID?
    let dropIndicator: SidebarDropIndicator?
    let dropIndicatorScope: SidebarWorkspaceReorderDropIndicatorScope
    let sidebarReorderIds: [UUID]
    let expandedChecklistWorkspaceIds: Set<UUID>
    let checklistAddFieldActivationTokens: [UUID: Int]
    let checklistPopoverWorkspaceId: UUID?
    let workspaceCount: Int
    let canCloseWorkspace: Bool
    let workspaceShortcutModifierSymbol: String
    let showsAgentActivity: Bool
    let showsNotificationMessage: Bool
    let liveShowsModifierShortcutHints: Bool
    let frozenShortcutHintsTabId: UUID?
    let frozenShortcutHintsValue: Bool
    let isBonsplitWorkspaceDropActive: Bool
    let rowSpacing: CGFloat
    let settings: SidebarTabItemSettingsSnapshot

    @MainActor
    func input(for workspaceId: UUID) -> SidebarWorkspaceRowInput? {
        guard let model = modelSnapshotsById[workspaceId],
              let workspace = workspaceSnapshotsById[workspaceId] else {
            return nil
        }

        let index = tabIndexById[workspaceId] ?? 0
        let isMultiSelected = selectedWorkspaceIds.contains(workspaceId)
        let contextMenuWorkspaceIds = isMultiSelected
            ? selectedContextTargetIds
            : [workspaceId]
        let unreadSummary = unreadSummariesByWorkspaceId[workspaceId]
            ?? SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
        let showsModifierShortcutHints = SidebarShortcutHintFreezePolicy().resolved(
            live: liveShowsModifierShortcutHints,
            currentTabId: workspaceId,
            frozenTabId: frozenShortcutHintsTabId,
            frozenValue: frozenShortcutHintsValue
        )
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: workspaceId,
            draggedTabId: draggedWorkspaceId,
            dropIndicator: dropIndicator,
            tabIds: sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: workspaceId,
            draggedTabId: draggedWorkspaceId,
            dropIndicator: dropIndicator,
            tabIds: sidebarReorderIds,
            indicatorScope: dropIndicatorScope
        )

        return SidebarWorkspaceRowInput(
            workspaceId: workspaceId,
            groupId: model.groupId,
            index: index,
            workspaceCount: workspaceCount,
            workspace: workspace,
            isActive: activeWorkspaceId == workspaceId,
            isMultiSelected: isMultiSelected,
            hasUserCustomTitle: model.hasUserCustomTitle,
            hasCustomTitle: model.hasCustomTitle,
            hasCustomDescription: model.hasCustomDescription,
            customTitle: model.customTitle,
            workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: index,
                workspaceCount: workspaceCount
            ),
            workspaceShortcutModifierSymbol: workspaceShortcutModifierSymbol,
            canCloseWorkspace: canCloseWorkspace,
            unreadCount: unreadSummary.unreadCount,
            latestNotificationText: showsNotificationMessage
                ? unreadSummary.latestNotificationText
                : nil,
            showsAgentActivity: showsAgentActivity,
            rowSpacing: rowSpacing,
            showsModifierShortcutHints: showsModifierShortcutHints,
            isPointerHovering: hoveredRowId == .workspace(workspaceId),
            isBeingDragged: draggedWorkspaceId == workspaceId,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            isBonsplitWorkspaceDropActive: isBonsplitWorkspaceDropActive,
            settings: settings,
            isChecklistExpanded: expandedChecklistWorkspaceIds.contains(workspaceId),
            checklistAddFieldActivationToken: checklistAddFieldActivationTokens[workspaceId] ?? 0,
            isChecklistPopoverPresented: checklistPopoverWorkspaceId == workspaceId,
            contextMenuPinState: WorkspaceActionDispatcher.PinState(
                targetWorkspaceIds: contextMenuWorkspaceIds,
                anchorWorkspaceId: workspaceId,
                pinned: !model.isPinned
            ),
            inferredTaskStatus: model.inferredTaskStatus,
            activeTodoOverride: model.activeTodoOverride,
            isTodoStatusHidden: model.isTodoStatusHidden
        )
    }
}
