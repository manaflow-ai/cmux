import AppKit
import CmuxFoundation
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    @ViewBuilder
    func sidebarWorkspaceGroupHeader(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool,
        showModifierHoldHints: Bool
    ) -> some View {
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
        let fullMemberWorkspaceIds = renderContext.tabs.compactMap { $0.groupId == group.id ? $0.id : nil }
        let groupMemberWorkspaceIds = fullMemberWorkspaceIds.isEmpty ? memberWorkspaceIds : fullMemberWorkspaceIds
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return groupMemberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + notificationStore.unreadCount(forTabId: workspaceId)
                }
            }
            return notificationStore.unreadCount(forTabId: group.anchorWorkspaceId)
        }()
        let anchorIds = [group.anchorWorkspaceId]
        let canMarkAnchorRead = notificationStore.canMarkWorkspaceRead(forTabIds: anchorIds)
        let canMarkAnchorUnread = notificationStore.canMarkWorkspaceUnread(forTabIds: anchorIds)
        let anchorHasLatestNotification = notificationStore.latestNotification(forTabId: group.anchorWorkspaceId) != nil
        // "Mark all workspaces in group" targets the contained workspaces only,
        // never the anchor: the anchor is the group's own row, whose read status
        // is owned by the separate "Mark Group as Read/Unread" actions.
        let nonAnchorMemberIds = groupMemberWorkspaceIds.filter { $0 != group.anchorWorkspaceId }
        let canMarkAllRead = notificationStore.canMarkWorkspaceRead(forTabIds: nonAnchorMemberIds)
        let canMarkAllUnread = notificationStore.canMarkWorkspaceUnread(forTabIds: nonAnchorMemberIds)
        let anchorIndex = renderContext.tabIndexById[group.anchorWorkspaceId] ?? 0
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: anchorIndex,
            workspaceCount: renderContext.workspaceCount
        )
        let modifierSymbol = renderContext.workspaceNumberShortcut.numberedDigitHintPrefix
        let showsHintForAnchor = showModifierHoldHints && modifierKeyMonitor.isModifierPressed
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
        let onDragStart: () -> NSItemProvider = { [anchorId = group.anchorWorkspaceId] in
            #if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(anchorId.uuidString.prefix(5))")
            #endif
            dragState.beginDragging(tabId: anchorId)
            return SidebarTabDragPayload.provider(for: anchorId)
        }
        let header = SidebarWorkspaceGroupHeaderView(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            memberCount: groupMemberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            shortcutDigit: shortcutDigit,
            shortcutModifierSymbol: modifierSymbol,
            showsShortcutHint: showsHintForAnchor,
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
            onDragStart: onDragStart,
            onToggleCollapsed: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: { [weak tabManager, anchorId = group.anchorWorkspaceId, selectedTabIds = $selectedTabIds, lastSidebarSelectionIndex = $lastSidebarSelectionIndex] in
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
            onTapPlus: { [weak tabManager, groupId = group.id, placement = newWorkspacePlacement] in
                guard let tabManager else { return }
                let resolved = placement
                    ?? UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
                _ = tabManager.createWorkspaceInGroup(groupId: groupId, placement: resolved)
            },
            onRunResolvedItem: { [weak tabManager, groupId = group.id] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            onRename: { [weak tabManager, groupId = group.id, currentName = group.name] in
                guard let tabManager else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            onTogglePinned: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onMarkRead: { [weak notificationStore, anchorId = group.anchorWorkspaceId] in
                notificationStore?.markRead(forTabId: anchorId)
            },
            onMarkUnread: { [weak notificationStore, anchorId = group.anchorWorkspaceId] in
                notificationStore?.markUnread(forTabId: anchorId)
            },
            onClearLatestNotifications: { [weak notificationStore, anchorId = group.anchorWorkspaceId] in
                notificationStore?.clearLatestNotification(forTabId: anchorId)
            },
            onMarkAllRead: { [weak tabManager, weak notificationStore, groupId = group.id, anchorId = group.anchorWorkspaceId] in
                guard let tabManager, let notificationStore else { return }
                // Resolve members live at action time: the header is .equatable()
                // and closures are excluded from ==, so a captured ID list could
                // go stale across a same-count membership swap.
                let ids = tabManager.tabs.compactMap { $0.groupId == groupId && $0.id != anchorId ? $0.id : nil }
                // Only touch members that are actually unread, so we never run
                // notification teardown on already-read workspaces.
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [weak tabManager, weak notificationStore, groupId = group.id, anchorId = group.anchorWorkspaceId] in
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
            onUngroup: { [weak tabManager, groupId = group.id] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager, groupId = group.id, groupName = group.name, memberCount = groupMemberWorkspaceIds.count] in
                guard let tabManager else { return }
                let otherMemberCount = max(memberCount - 1, 0)
                guard confirmDeleteWorkspaceGroup(groupName: groupName, otherMemberCount: otherMemberCount) else { return }
                tabManager.deleteWorkspaceGroup(groupId: groupId)
            },
            onEditConfig: {
                SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
            },
            onOpenDocs: {
                SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
            }
        )
        .equatable()
        .id(group.anchorWorkspaceId)
        .accessibilityIdentifier("sidebarWorkspaceGroup.\(group.id.uuidString)")

        header
            .sidebarWorkspaceFrameAnchor(
                id: group.anchorWorkspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
    }
}
