import AppKit
import CmuxFoundation
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    func sidebarWorkspaceGroupRowSnapshot(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary],
        notificationIndex: SidebarWorkspaceNotificationIndex,
        shouldCollectWorkspaceDropTargets: Bool,
        showModifierHoldHints: Bool
    ) -> SidebarWorkspaceGroupRowSnapshot {
        let settings = renderContext.tabItemSettings
        let isAnchorActive = tabManager.selectedTabId == group.anchorWorkspaceId
        let anchorCwd = renderContext.workspaceById[group.anchorWorkspaceId]?.currentDirectory
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: resolvedConfig?.iconSymbol
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return memberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + (unreadSummariesByWorkspaceId[workspaceId]?.unreadCount ?? 0)
                }
            }
            return unreadSummariesByWorkspaceId[group.anchorWorkspaceId]?.unreadCount ?? 0
        }()
        let anchorIds = [group.anchorWorkspaceId]
        let canMarkAnchorRead = anchorIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) > 0
        }
        let canMarkAnchorUnread = anchorIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) == 0
        }
        let anchorHasLatestNotification = notificationIndex.hasNotification(
            workspaceId: group.anchorWorkspaceId
        )
        // "Mark all workspaces in group" targets the contained workspaces only,
        // never the anchor: the anchor is the group's own row, whose read status
        // is owned by the separate "Mark Group as Read/Unread" actions.
        let nonAnchorMemberIds = memberWorkspaceIds.filter { $0 != group.anchorWorkspaceId }
        let canMarkAllRead = nonAnchorMemberIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) > 0
        }
        let canMarkAllUnread = nonAnchorMemberIds.contains {
            (unreadSummariesByWorkspaceId[$0]?.unreadCount ?? 0) == 0
        }
        let anchorIndex = renderContext.tabIndexById[group.anchorWorkspaceId] ?? 0
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: anchorIndex,
            workspaceCount: renderContext.workspaceCount
        )
        let modifierSymbol = renderContext.workspaceNumberShortcut.numberedDigitHintPrefix
        let showsHintForAnchor = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
        // Hover is owned by the AppKit table (single pointer owner); the
        // snapshot field stays false and cells receive hover at configure time.
        let isPointerHovering = false
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: group.anchorWorkspaceId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: group.anchorWorkspaceId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        return SidebarWorkspaceGroupRowSnapshot(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            shortcutDigit: shortcutDigit,
            shortcutModifierSymbol: modifierSymbol,
            showsShortcutHint: showsHintForAnchor,
            isPointerHovering: isPointerHovering,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: cwdContextMenuItems,
            newWorkspacePlacement: newWorkspacePlacement,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.anchorWorkspaceId,
            isBeingDragged: dragState.draggedTabId == group.anchorWorkspaceId,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            shouldCollectWorkspaceDropTargets: shouldCollectWorkspaceDropTargets
        )
    }

    /// Closure bundle for the AppKit group-header cell and its menus. Model
    /// references appear only inside user-invoked action closures; drag start
    /// is handled by the table's native drag source instead of an
    /// `onDragStart` closure.
    func sidebarWorkspaceGroupHeaderActions(
        snapshot: SidebarWorkspaceGroupRowSnapshot
    ) -> SidebarWorkspaceGroupHeaderActions {
        SidebarWorkspaceGroupHeaderActions(
            onToggleCollapsed: { [weak tabManager, groupId = snapshot.groupId] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: { [weak tabManager, anchorId = snapshot.anchorWorkspaceId, selectedTabIds = $selectedTabIds, lastSidebarSelectionIndex = $lastSidebarSelectionIndex] in
                guard let tabManager else { return }
                guard let anchorTab = tabManager.tabs.first(where: { $0.id == anchorId }) else { return }
                tabManager.selectWorkspace(anchorTab)
                if selectedTabIds.wrappedValue != [anchorId] {
                    selectedTabIds.wrappedValue = [anchorId]
                }
                if let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == anchorId }) {
                    lastSidebarSelectionIndex.wrappedValue = anchorIndex
                }
            },
            onTapPlus: { [weak tabManager, groupId = snapshot.groupId, placement = snapshot.newWorkspacePlacement] in
                guard let tabManager else { return }
                let resolved = placement
                    ?? UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
                _ = tabManager.createWorkspaceInGroup(groupId: groupId, placement: resolved)
            },
            onRunResolvedItem: { [weak tabManager, groupId = snapshot.groupId] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            onRename: { [weak tabManager, groupId = snapshot.groupId, currentName = snapshot.name] in
                guard let tabManager else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            onTogglePinned: { [weak tabManager, groupId = snapshot.groupId] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onMarkRead: { [weak notificationStore, anchorId = snapshot.anchorWorkspaceId] in
                guard let notificationStore,
                      notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markRead(forTabId: anchorId)
            },
            onMarkUnread: { [weak notificationStore, anchorId = snapshot.anchorWorkspaceId] in
                guard let notificationStore,
                      notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markUnread(forTabId: anchorId)
            },
            onClearLatestNotifications: { [weak notificationStore, anchorId = snapshot.anchorWorkspaceId] in
                notificationStore?.clearLatestNotification(forTabId: anchorId)
            },
            onMarkAllRead: { [weak tabManager, weak notificationStore, groupId = snapshot.groupId, anchorId = snapshot.anchorWorkspaceId] in
                guard let tabManager, let notificationStore else { return }
                // Resolve members live at action time so a same-count
                // membership swap between snapshot build and click can't
                // target stale ids.
                let ids = tabManager.tabs.compactMap { $0.groupId == groupId && $0.id != anchorId ? $0.id : nil }
                // Only touch members that are actually unread, so we never run
                // notification teardown on already-read workspaces.
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [weak tabManager, weak notificationStore, groupId = snapshot.groupId, anchorId = snapshot.anchorWorkspaceId] in
                guard let tabManager, let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { $0.groupId == groupId && $0.id != anchorId ? $0.id : nil }
                // Only mark members that are not already unread. Calling
                // markUnread on an already-unread member would set its manual
                // unread flag, which a later notification dismissal cannot
                // clear, leaving the workspace stuck unread.
                for id in ids where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                    notificationStore.markUnread(forTabId: id)
                }
            },
            onUngroup: { [weak tabManager, groupId = snapshot.groupId] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager, groupId = snapshot.groupId, fallbackName = snapshot.name, fallbackAnchorId = snapshot.anchorWorkspaceId] in
                guard let tabManager,
                      let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                        groupId: groupId,
                        fallbackGroupName: fallbackName,
                        fallbackAnchorWorkspaceId: fallbackAnchorId
                      ) else { return }
                if confirmation.containedWorkspaceCount > 0 {
                    guard confirmDeleteWorkspaceGroup(
                        groupName: confirmation.groupName,
                        memberCount: confirmation.containedWorkspaceCount
                    ) else { return }
                }
                tabManager.workspaceGrouping.deleteWorkspaceGroup(confirmed: confirmation)
            },
            onEditConfig: {
                SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            },
            onOpenDocs: {
                SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
            }
        )
    }
}
