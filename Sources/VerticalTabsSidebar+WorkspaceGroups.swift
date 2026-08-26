import AppKit
import CmuxFoundation
import CmuxNotifications
import SwiftUI
import CmuxSettings
import CmuxWorkspaces

extension VerticalTabsSidebar {
    func sidebarWorkspaceGroupTableConfiguration(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let settings = renderContext.tabItemSettings
        let anchorId = group.anchorWorkspaceId
        let liveAnchorId = group.liveAnchorWorkspaceId
        let isAnchorActive = liveAnchorId.map { tabManager.selectedTabId == $0 } ?? false
        let isMultiSelected = liveAnchorId.map { selectedTabIds.contains($0) } ?? false
            && selectedTabIds.count > 1
        let anchorCwd = liveAnchorId.flatMap { renderContext.workspaceById[$0]?.currentDirectory }
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: resolvedConfig?.iconSymbol
        )
        let multiSelectionBackgroundStyle = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: false,
            isMultiSelected: true,
            customColorHex: effectiveColor,
            colorScheme: renderContext.environment.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        // The AppKit controller applies the current unread snapshot after row
        // construction, keeping this root projection outside Observation.
        let unreadSnapshot = SidebarUnreadSnapshot()
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return memberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + unreadSnapshot.unreadCount(forWorkspaceId: workspaceId)
                }
            }
            return liveAnchorId.map { unreadSnapshot.unreadCount(forWorkspaceId: $0) } ?? 0
        }()
        let anchorIds = liveAnchorId.map { [$0] } ?? []
        let canMarkAnchorRead = unreadSnapshot.canMarkWorkspaceRead(forWorkspaceIds: anchorIds)
        let canMarkAnchorUnread = unreadSnapshot.canMarkWorkspaceUnread(forWorkspaceIds: anchorIds)
        let anchorHasLatestNotification = liveAnchorId.map {
            unreadSnapshot.summary(forWorkspaceId: $0).hasLatestNotification
        } ?? false
        // "Mark all workspaces in group" targets the contained workspaces only,
        // never the anchor: the anchor is the group's own row, whose read status
        // is owned by the separate "Mark Group as Read/Unread" actions.
        let nonAnchorMemberIds = memberWorkspaceIds.filter { memberId in
            liveAnchorId.map { $0 != memberId } ?? true
        }
        let canMarkAllRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: nonAnchorMemberIds
        )
        let canMarkAllUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: nonAnchorMemberIds
        )
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: anchorId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: anchorId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds,
            indicatorScope: dragState.dropIndicatorScope
        )
        let model = SidebarGroupHeaderRowModel(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            shortcutHintText: nil,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            globalFontMagnificationPercent: renderContext.environment.globalFontMagnificationPercent,
            cwdContextMenuItems: cwdContextMenuItems,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == anchorId,
            isBeingDragged: dragState.draggedTabId == anchorId,
            topDropIndicatorVisible: topDropIndicatorVisible,
            bottomDropIndicatorVisible: bottomDropIndicatorVisible,
            colorSchemeIsDark: renderContext.environment.colorScheme == .dark
        )
        let actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: { [weak tabManager, groupId = group.id] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: {
                [weak tabManager, anchorId, selectedTabIds = $selectedTabIds,
                 lastSidebarSelectionIndex = $lastSidebarSelectionIndex] modifiers in
                guard let tabManager else { return }
                guard let anchorTab = tabManager.tabs.first(where: { $0.id == anchorId }) else { return }
                if modifiers.contains(.command) || modifiers.contains(.shift) {
                    let anchorIds = Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
                    let toggledSelection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                        current: selectedTabIds.wrappedValue,
                        clickedAnchorId: anchorId,
                        anchorIds: anchorIds
                    )
                    selectedTabIds.wrappedValue = toggledSelection
                    tabManager.selectWorkspace(anchorTab)
                } else {
                    tabManager.selectWorkspace(anchorTab)
                    if selectedTabIds.wrappedValue != [anchorId] {
                        selectedTabIds.wrappedValue = [anchorId]
                    }
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
            onMarkRead: { [weak notificationStore, liveAnchorId] in
                guard let liveAnchorId else { return }
                notificationStore?.markRead(forTabId: liveAnchorId)
            },
            onMarkUnread: { [weak notificationStore, liveAnchorId] in
                guard let liveAnchorId else { return }
                notificationStore?.markUnread(forTabId: liveAnchorId)
            },
            onClearLatestNotifications: { [weak notificationStore, liveAnchorId] in
                guard let liveAnchorId else { return }
                notificationStore?.clearLatestNotification(forTabId: liveAnchorId)
            },
            onMarkAllRead: { [weak tabManager, weak notificationStore, groupId = group.id, liveAnchorId] in
                guard let tabManager, let notificationStore else { return }
                // Resolve members live at action time: closures are excluded
                // from model equality, so a captured ID list could go stale
                // across a same-count membership swap.
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != liveAnchorId ? tab.id : nil
                }
                // Only touch members that are actually unread, so we never run
                // notification teardown on already-read workspaces.
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [weak tabManager, weak notificationStore, groupId = group.id, liveAnchorId] in
                guard let tabManager, let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != liveAnchorId ? tab.id : nil
                }
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
                if group.isPinned || confirmation.containedWorkspaceCount > 0 {
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
            environment: renderContext.environment,
            unreadDependencyWorkspaceIds: Set(memberWorkspaceIds)
                .union(liveAnchorId.map { [$0] } ?? []),
            unreadRebuild: {
                [model, liveAnchorId,
                 isCollapsed = group.isCollapsed, memberWorkspaceIds,
                 nonAnchorMemberIds] snapshot in
                // Membership and collapse are structural row inputs, so their
                // changes rebuild this configuration. Reuse the render context's
                // indexed members instead of rescanning every tab per unread row.
                var fresh = model
                fresh.anchorUnreadCount = isCollapsed
                    ? memberWorkspaceIds.reduce(0) {
                        $0 + snapshot.unreadCount(forWorkspaceId: $1)
                    }
                    : liveAnchorId.map { snapshot.unreadCount(forWorkspaceId: $0) } ?? 0
                fresh.canMarkRead = snapshot.canMarkWorkspaceRead(
                    forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
                )
                fresh.canMarkUnread = snapshot.canMarkWorkspaceUnread(
                    forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
                )
                fresh.hasLatestNotifications = liveAnchorId.map {
                    snapshot.summary(forWorkspaceId: $0).hasLatestNotification
                } ?? false
                fresh.canMarkAllRead = snapshot.canMarkWorkspaceRead(
                    forWorkspaceIds: nonAnchorMemberIds
                )
                fresh.canMarkAllUnread = snapshot.canMarkWorkspaceUnread(
                    forWorkspaceIds: nonAnchorMemberIds
                )
                return fresh
            }
        )
    }

    func sidebarWorkspaceGroupRowSnapshot(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        unreadSnapshot: SidebarUnreadSnapshot,
        notificationIndex: SidebarWorkspaceNotificationIndex,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> SidebarWorkspaceGroupRowSnapshot {
        let unreadSummariesByWorkspaceId = unreadSnapshot.summaryByWorkspaceId
        let settings = renderContext.tabItemSettings
        let anchorId = group.anchorWorkspaceId
        let liveAnchorId = group.liveAnchorWorkspaceId
        let isAnchorActive = liveAnchorId.map { tabManager.selectedTabId == $0 } ?? false
        let isMultiSelected = liveAnchorId.map { selectedTabIds.contains($0) } ?? false
            && selectedTabIds.count > 1
        let anchorCwd = liveAnchorId.flatMap { renderContext.workspaceById[$0]?.currentDirectory }
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: resolvedConfig?.iconSymbol
        )
        let multiSelectionBackgroundStyle = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: false,
            isMultiSelected: true,
            customColorHex: effectiveColor,
            colorScheme: renderContext.environment.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
        let cwdContextMenuItems = resolvedConfig?.contextMenuItems ?? []
        let newWorkspacePlacement = resolvedConfig?.newWorkspacePlacement
        let anchorUnreadCount: Int = {
            if group.isCollapsed {
                return memberWorkspaceIds.reduce(0) { partial, workspaceId in
                    partial + (unreadSummariesByWorkspaceId[workspaceId]?.unreadCount ?? 0)
                }
            }
            return liveAnchorId.flatMap { unreadSummariesByWorkspaceId[$0]?.unreadCount } ?? 0
        }()
        let canMarkAnchorRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
        )
        let canMarkAnchorUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: liveAnchorId.map { [$0] } ?? []
        )
        let anchorHasLatestNotification = liveAnchorId.map {
            notificationIndex.hasNotification(workspaceId: $0)
        } ?? false
        // "Mark all workspaces in group" targets the contained workspaces only,
        // never the anchor: the anchor is the group's own row, whose read status
        // is owned by the separate "Mark Group as Read/Unread" actions.
        let nonAnchorMemberIds = memberWorkspaceIds.filter { memberId in
            liveAnchorId.map { $0 != memberId } ?? true
        }
        let canMarkAllRead = unreadSnapshot.canMarkWorkspaceRead(
            forWorkspaceIds: nonAnchorMemberIds
        )
        let canMarkAllUnread = unreadSnapshot.canMarkWorkspaceUnread(
            forWorkspaceIds: nonAnchorMemberIds
        )
        let rowId = SidebarWorkspaceRenderItemID.group(group.id)
        let isPointerHovering = pointerInteractionMonitor.hoveredRowId == rowId
        let topDropIndicatorVisible = SidebarTabDropIndicatorPredicate().topVisible(
            forTabId: anchorId,
            draggedTabId: dragState.draggedTabId,
            dropIndicator: dragState.dropIndicator,
            tabIds: renderContext.sidebarReorderIds
        )
        let bottomDropIndicatorVisible = SidebarTabDropIndicatorPredicate().bottomVisible(
            forTabId: anchorId,
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
            isMultiSelected: isMultiSelected,
            multiSelectionBackgroundStyle: multiSelectionBackgroundStyle,
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: anchorUnreadCount,
            canMarkRead: canMarkAnchorRead,
            canMarkUnread: canMarkAnchorUnread,
            hasLatestNotifications: anchorHasLatestNotification,
            canMarkAllRead: canMarkAllRead,
            canMarkAllUnread: canMarkAllUnread,
            shortcutDigit: nil,
            shortcutModifierSymbol: nil,
            showsShortcutHint: false,
            isPointerHovering: isPointerHovering,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: cwdContextMenuItems,
            newWorkspacePlacement: newWorkspacePlacement,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.sidebarReorderIds.first == anchorId,
            isBeingDragged: dragState.draggedTabId == anchorId,
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
        // An empty header has no live workspace capability. Carry the typed
        // group identity so the resolver can route it through `.reorderGroup`;
        // live groups continue to carry their anchor workspace id.
        let dragPayloadId = snapshot.memberCount == 0
            ? snapshot.groupId
            : snapshot.anchorWorkspaceId
        let onDragStart: () -> NSItemProvider = { [dragPayloadId] in
#if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(dragPayloadId.uuidString.prefix(5))")
#endif
            dragState.beginDragging(tabId: dragPayloadId)
            return SidebarTabDragPayload(tabId: dragPayloadId).provider()
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
            isMultiSelected: snapshot.isMultiSelected,
            multiSelectionBackgroundStyle: snapshot.multiSelectionBackgroundStyle,
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
            onFocusAnchor: { [weak tabManager, anchorId = snapshot.anchorWorkspaceId, selectedTabIds = $selectedTabIds, lastSidebarSelectionIndex = $lastSidebarSelectionIndex] modifiers in
                guard let tabManager else { return }
                guard let anchorTab = tabManager.tabs.first(where: { $0.id == anchorId }) else { return }
                if modifiers.contains(.command) || modifiers.contains(.shift) {
                    let anchorIds = Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
                    let toggledSelection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                        current: selectedTabIds.wrappedValue,
                        clickedAnchorId: anchorId,
                        anchorIds: anchorIds
                    )
                    selectedTabIds.wrappedValue = toggledSelection
                    tabManager.selectWorkspace(anchorTab)
                } else {
                    tabManager.selectWorkspace(anchorTab)
                    if selectedTabIds.wrappedValue != [anchorId] {
                        selectedTabIds.wrappedValue = [anchorId]
                    }
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
            onMarkRead: { [weak notificationStore, anchorId = snapshot.anchorWorkspaceId, memberCount = snapshot.memberCount] in
                guard let notificationStore,
                      memberCount > 0,
                      notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markRead(forTabId: anchorId)
            },
            onMarkUnread: { [weak notificationStore, anchorId = snapshot.anchorWorkspaceId, memberCount = snapshot.memberCount] in
                guard let notificationStore,
                      memberCount > 0,
                      notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markUnread(forTabId: anchorId)
            },
            onClearLatestNotifications: {
                [weak notificationStore, anchorId = snapshot.anchorWorkspaceId,
                 memberCount = snapshot.memberCount] in
                guard memberCount > 0 else { return }
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
                if snapshot.isPinned || confirmation.containedWorkspaceCount > 0 {
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
