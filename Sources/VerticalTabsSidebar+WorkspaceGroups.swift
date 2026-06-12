import AppKit
import SwiftUI

extension VerticalTabsSidebar {
    @ViewBuilder
    func sidebarWorkspaceGroupHeader(
        group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        renderContext: WorkspaceListRenderContext,
        shouldCollectWorkspaceDropTargets: Bool,
        role: SidebarWorkspaceRowRenderRole = .list
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
        // The group header badge is always a rollup of every member's unread
        // (anchor included — `memberWorkspaceIds` contains the anchor), whether
        // the group is collapsed or expanded. Expanded members still show their
        // own per-row badges; the header total tells you the group has unread
        // activity without expanding it. (Members hidden under a collapsed
        // group have no row of their own, so the rollup is the only signal.)
        let groupUnreadCount: Int = memberWorkspaceIds.reduce(0) { partial, workspaceId in
            partial + notificationStore.unreadCount(forTabId: workspaceId)
        }
        let anchorIndex = renderContext.tabIndexById[group.anchorWorkspaceId] ?? 0
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: anchorIndex,
            workspaceCount: renderContext.workspaceCount
        )
        let modifierSymbol = renderContext.workspaceNumberShortcut.numberedDigitHintPrefix
        let showsHintForAnchor = modifierKeyMonitor.isModifierPressed
        // Dragging a group header reorders the whole group at top level; the
        // shared reorder helpers handle the anchor/top-level scope.
        let onReorderChanged: (CGPoint, CGFloat) -> Void = { [anchorId = group.anchorWorkspaceId, renderContext] startLocation, translationHeight in
            sidebarReorderGestureChanged(
                draggedId: anchorId,
                startLocationY: startLocation.y,
                translationHeight: translationHeight,
                renderContext: renderContext
            )
        }
        let onReorderEnded: (CGPoint, CGFloat) -> Void = { [anchorId = group.anchorWorkspaceId] _, _ in
            sidebarReorderGestureEnded(draggedId: anchorId)
        }
        // Computed in the parent and applied as opacity below (not passed into
        // the header view) so the gesture-hosting header's inputs stay constant
        // during a drag and its in-flight `DragGesture` is not torn down.
        let isBeingDragged = role == .list && dragState.draggedTabId == group.anchorWorkspaceId

        let header = SidebarWorkspaceGroupHeaderView(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: isAnchorActive,
            isReorderDropTarget: role == .list && dragState.dropIntoGroupAnchorId == group.anchorWorkspaceId,
            memberCount: memberWorkspaceIds.count,
            groupUnreadCount: groupUnreadCount,
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
            topDropIndicatorVisible: false,
            onReorderChanged: onReorderChanged,
            onReorderEnded: onReorderEnded,
            isReorderEnabled: role == .list,
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
                let resolved = placement ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
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
            onUngroup: { [weak tabManager, groupId = group.id] in
                tabManager?.ungroupWorkspaceGroup(groupId: groupId)
            },
            onDelete: { [weak tabManager, groupId = group.id, groupName = group.name, memberCount = memberWorkspaceIds.count] in
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

        if role == .dragFollower {
            header
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            header
                .opacity(isBeingDragged ? 0 : 1)
                // No `.id(group.anchorWorkspaceId)` here: identity comes from the
                // ForEach (`id: \.scrollAnchorWorkspaceId`, which equals the anchor id),
                // so promote/ungroup keeps the same slot and the morph transition runs.
                .accessibilityIdentifier("sidebarWorkspaceGroup.\(group.id.uuidString)")
                .preference(key: SidebarWorkspaceRowIdsPreferenceKey.self, value: Set([group.anchorWorkspaceId]))
                .sidebarWorkspaceFrameAnchor(
                    id: group.anchorWorkspaceId,
                    isEnabled: shouldCollectWorkspaceDropTargets
                )
        }
    }
}
