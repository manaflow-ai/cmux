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
        let actions = makeWorkspaceGroupHeaderActions(
            groupId: group.id,
            fallbackGroupName: group.name,
            fallbackAnchorWorkspaceId: group.anchorWorkspaceId,
            placement: newWorkspacePlacement,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
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
        // live groups resolve their current anchor at drag start. A stale
        // non-empty row fails closed instead of carrying a closed workspace
        // identity; an empty group carries its stable group identity.
        let onDragStart: () -> NSItemProvider = { [weak tabManager,
                                                    groupId = snapshot.groupId,
                                                    isEmpty = snapshot.memberCount == 0] in
            let dragPayloadId: UUID
            if let liveAnchorId = tabManager?.workspaceGroupAnchor(for: groupId)?.id {
                dragPayloadId = liveAnchorId
            } else if isEmpty {
                dragPayloadId = groupId
            } else {
                return NSItemProvider()
            }
#if DEBUG
            cmuxDebugLog("sidebar.onDrag groupAnchor=\(dragPayloadId.uuidString.prefix(5))")
#endif
            dragState.beginDragging(tabId: dragPayloadId)
            return SidebarTabDragPayload(tabId: dragPayloadId).provider()
        }
        let actions = makeWorkspaceGroupHeaderActions(
            groupId: snapshot.groupId,
            fallbackGroupName: snapshot.name,
            fallbackAnchorWorkspaceId: snapshot.anchorWorkspaceId,
            placement: snapshot.newWorkspacePlacement,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
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
            actions: actions,
            onContextMenuAppear: {},
            onContextMenuDisappear: {}
        )

        return SidebarWorkspaceGroupRowView(
            header: header,
            groupId: snapshot.groupId,
            anchorWorkspaceId: snapshot.anchorWorkspaceId,
            shouldCollectWorkspaceDropTargets: snapshot.shouldCollectWorkspaceDropTargets,
            onPointerFrameChange: { [pointerInteractionMonitor] frame in
                pointerInteractionMonitor.updateGroupFrame(frame, for: rowId)
            },
            onPointerFrameDisappear: { [pointerInteractionMonitor] in
                pointerInteractionMonitor.removeFrame(for: rowId)
            }
        )
    }

    /// Builds the one live action bundle shared by the SwiftUI and AppKit
    /// group-header renderers. The stable group id is captured; mutable anchor
    /// and member ids are resolved only when an action is invoked.
    @MainActor
    private func makeWorkspaceGroupHeaderActions(
        groupId: UUID,
        fallbackGroupName: String,
        fallbackAnchorWorkspaceId: UUID,
        placement: WorkspaceGroupNewPlacement?,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) -> SidebarGroupHeaderRowActions {
        let tabManager = self.tabManager
        let notificationStore = self.notificationStore
        let resolveLiveAnchor: () -> (TabManager, UUID)? = { [weak tabManager] in
            guard let tabManager,
                  let anchorId = tabManager.workspaceGroupAnchor(for: groupId)?.id else {
                return nil
            }
            return (tabManager, anchorId)
        }
        let resolvePlacement: () -> WorkspaceGroupNewPlacement = {
            placement
                ?? UserDefaultsSettingsClient(defaults: .standard)
                    .value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        }
        let resolveNotificationState: () -> SidebarGroupHeaderRowActions.NotificationState = {
            [resolveLiveAnchor, weak notificationStore] in
            guard let (tabManager, anchorId) = resolveLiveAnchor(),
                  let notificationStore else {
                return .unavailable
            }
            let memberIds = tabManager.tabs.compactMap { tab in
                tab.groupId == groupId && tab.id != anchorId ? tab.id : nil
            }
            return .init(
                canMarkRead: notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]),
                canMarkUnread: notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]),
                hasLatestNotifications: notificationStore.latestNotification(forTabId: anchorId) != nil,
                canMarkAllRead: memberIds.contains {
                    notificationStore.canMarkWorkspaceRead(forTabIds: [$0])
                },
                canMarkAllUnread: memberIds.contains {
                    notificationStore.canMarkWorkspaceUnread(forTabIds: [$0])
                }
            )
        }

        var actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
            },
            onFocusAnchor: { [weak tabManager] modifiers in
                guard let tabManager else { return }
                Self.focusWorkspaceGroupAnchor(
                    groupId: groupId,
                    modifiers: modifiers,
                    tabManager: tabManager,
                    selectedTabIds: selectedTabIds,
                    lastSidebarSelectionIndex: lastSidebarSelectionIndex
                )
            },
            onTapPlus: { [weak tabManager] in
                guard let tabManager else { return }
                _ = tabManager.createWorkspaceInGroup(
                    groupId: groupId,
                    placement: resolvePlacement()
                )
            },
            onRunResolvedItem: { [weak tabManager] item in
                guard let tabManager else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: groupId
                )
            },
            onRename: { [weak tabManager] in
                guard let tabManager else { return }
                let currentName = tabManager.workspaceGroups
                    .first(where: { $0.id == groupId })?.name ?? fallbackGroupName
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: groupId,
                    currentName: currentName
                )
            },
            onTogglePinned: { [weak tabManager] in
                tabManager?.toggleWorkspaceGroupPinned(groupId: groupId)
            },
            onMarkRead: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.canMarkWorkspaceRead(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markRead(forTabId: anchorId)
            },
            onMarkUnread: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorId]) else {
                    return
                }
                notificationStore.markUnread(forTabId: anchorId)
            },
            onClearLatestNotifications: { [resolveLiveAnchor, weak notificationStore] in
                guard let (_, anchorId) = resolveLiveAnchor(),
                      let notificationStore,
                      notificationStore.latestNotification(forTabId: anchorId) != nil else {
                    return
                }
                notificationStore.clearLatestNotification(forTabId: anchorId)
            },
            onMarkAllRead: { [resolveLiveAnchor, weak notificationStore] in
                guard let (tabManager, anchorId) = resolveLiveAnchor(),
                      let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != anchorId ? tab.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [resolveLiveAnchor, weak notificationStore] in
                guard let (tabManager, anchorId) = resolveLiveAnchor(),
                      let notificationStore else { return }
                let ids = tabManager.tabs.compactMap { tab in
                    tab.groupId == groupId && tab.id != anchorId ? tab.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                    notificationStore.markUnread(forTabId: id)
                }
            },
            onUngroup: { [weak tabManager] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager] in
                guard let tabManager,
                      let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                          groupId: groupId,
                          fallbackGroupName: fallbackGroupName,
                          fallbackAnchorWorkspaceId: fallbackAnchorWorkspaceId
                      ) else {
                    return
                }
                let isPinned = tabManager.workspaceGroups
                    .first(where: { $0.id == groupId })?.isPinned ?? false
                if isPinned || confirmation.containedWorkspaceCount > 0 {
                    guard confirmDeleteWorkspaceGroup(
                        groupName: confirmation.groupName,
                        memberCount: confirmation.containedWorkspaceCount
                    ) else {
                        return
                    }
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
        actions.notificationState = resolveNotificationState
        return actions
    }

    /// Applies one shared group-header selection action to the live anchor.
    @MainActor
    static func focusWorkspaceGroupAnchor(
        groupId: UUID,
        modifiers: NSEvent.ModifierFlags,
        tabManager: TabManager,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>
    ) {
        let anchorId: UUID
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            guard let anchor = tabManager.workspaceGroupAnchor(for: groupId) else { return }
            let selection = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                current: selectedTabIds.wrappedValue,
                clickedAnchorId: anchor.id,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId))
            )
            selectedTabIds.wrappedValue = selection
            guard let selectedAnchor = tabManager.selectWorkspaceGroupAnchor(for: groupId) else { return }
            anchorId = selectedAnchor.id
        } else {
            guard let selectedAnchor = tabManager.selectWorkspaceGroupAnchor(for: groupId) else { return }
            anchorId = selectedAnchor.id
            if selectedTabIds.wrappedValue != [anchorId] {
                selectedTabIds.wrappedValue = [anchorId]
            }
        }
        lastSidebarSelectionIndex.wrappedValue = tabManager.tabs.firstIndex { $0.id == anchorId }
    }
}
