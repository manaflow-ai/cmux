import AppKit
import CmuxFoundation
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    func sidebarWorkspaceGroupTableConfiguration(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        showModifierHoldHints: Bool
    ) -> SidebarWorkspaceTableRowConfiguration {
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
        let nonAnchorMemberIds = memberWorkspaceIds.filter { $0 != group.anchorWorkspaceId }
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
        let shortcutHintText: String? = {
            guard showsHintForAnchor, let shortcutDigit else { return nil }
            return "\(modifierSymbol)\(shortcutDigit)"
        }()
        let model = SidebarGroupHeaderRowModel(
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
            shortcutHintText: shortcutHintText,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            globalFontMagnificationPercent: renderContext.environment.globalFontMagnificationPercent,
            cwdContextMenuItems: cwdContextMenuItems,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == group.anchorWorkspaceId,
            isBeingDragged: dragState.draggedTabId == group.anchorWorkspaceId,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible
        )
        let actions = SidebarGroupHeaderRowActions(
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
                // Resolve members live at action time: closures are excluded
                // from model equality, so a captured ID list could go stale
                // across a same-count membership swap.
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
            onDelete: { [weak tabManager, groupId = group.id] in
                guard let tabManager,
                      let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                        groupId: groupId,
                        fallbackGroupName: group.name,
                        fallbackAnchorWorkspaceId: group.anchorWorkspaceId
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
        return SidebarWorkspaceTableRowConfiguration(
            groupHeaderModel: model,
            actions: actions,
            environment: renderContext.environment
        )
    }

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
        let rowId = SidebarWorkspaceRenderItemID.group(group.id)
        let isPointerHovering = pointerInteractionMonitor.hoveredRowId == rowId
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

    /// Assembles one group row from immutable values when the lazy stack asks
    /// for it. Model references appear only inside user-invoked action
    /// closures; row realization performs no observable reads or mutations.
    func sidebarWorkspaceGroupRow(
        snapshot: SidebarWorkspaceGroupRowSnapshot
    ) -> SidebarWorkspaceGroupRowView {
        let rowId = SidebarWorkspaceRenderItemID.group(snapshot.groupId)
        let onDragStart: () -> NSItemProvider = { [anchorId = snapshot.anchorWorkspaceId] in
#if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(anchorId.uuidString.prefix(5))")
#endif
            dragState.beginDragging(tabId: anchorId)
            return SidebarTabDragPayload(tabId: anchorId).provider()
        }
        let header = SidebarWorkspaceGroupHeaderView(
            groupId: snapshot.groupId,
            anchorWorkspaceId: snapshot.anchorWorkspaceId,
            name: snapshot.name,
            iconSymbol: snapshot.iconSymbol,
            tintHex: snapshot.tintHex,
            isCollapsed: snapshot.isCollapsed,
            isPinned: snapshot.isPinned,
            isAnchorActive: snapshot.isAnchorActive,
            memberCount: snapshot.memberCount,
            anchorUnreadCount: snapshot.anchorUnreadCount,
            canMarkRead: snapshot.canMarkRead,
            canMarkUnread: snapshot.canMarkUnread,
            hasLatestNotifications: snapshot.hasLatestNotifications,
            canMarkAllRead: snapshot.canMarkAllRead,
            canMarkAllUnread: snapshot.canMarkAllUnread,
            shortcutDigit: snapshot.shortcutDigit,
            shortcutModifierSymbol: snapshot.shortcutModifierSymbol,
            showsShortcutHint: snapshot.showsShortcutHint,
            isPointerHovering: snapshot.isPointerHovering,
            shortcutHintXOffset: snapshot.shortcutHintXOffset,
            shortcutHintYOffset: snapshot.shortcutHintYOffset,
            fontScale: snapshot.fontScale,
            cwdContextMenuItems: snapshot.cwdContextMenuItems,
            newWorkspacePlacement: snapshot.newWorkspacePlacement,
            rowSpacing: snapshot.rowSpacing,
            isFirstRow: snapshot.isFirstRow,
            isBeingDragged: snapshot.isBeingDragged,
            topDropIndicatorVisible: snapshot.topDropIndicatorVisible,
            bottomDropIndicatorVisible: snapshot.bottomDropIndicatorVisible,
            onDragStart: onDragStart,
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
            },
            onContextMenuAppear: {},
            onContextMenuDisappear: {}
        )

        return SidebarWorkspaceGroupRowView(
            header: header,
            groupId: snapshot.groupId,
            anchorWorkspaceId: snapshot.anchorWorkspaceId,
            shouldCollectWorkspaceDropTargets: snapshot.shouldCollectWorkspaceDropTargets,
            onPointerFrameChange: { [pointerInteractionMonitor, workspaceId = snapshot.anchorWorkspaceId] frame in
                pointerInteractionMonitor.updateFrame(frame, for: rowId, workspaceId: workspaceId)
            },
            onPointerFrameDisappear: { [pointerInteractionMonitor] in
                pointerInteractionMonitor.removeFrame(for: rowId)
            }
        )
    }
}
