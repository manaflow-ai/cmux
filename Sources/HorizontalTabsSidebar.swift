import AppKit
import CmuxFoundation
import SwiftUI

private struct HorizontalWorkspaceTabSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isActive: Bool
    let isMultiSelected: Bool
    let isPinned: Bool
    let customColorHex: String?
    let unreadCount: Int
    let shortcutLabel: String?
    let canCloseWorkspace: Bool
    let accessibilityTitle: String
}

private struct HorizontalWorkspaceTabRenderModel {
    let snapshots: [HorizontalWorkspaceTabSnapshot]
    let renderedIds: [UUID]
    let renderedIndexById: [UUID: Int]
    let workspaceById: [UUID: Workspace]
    let closeableIds: Set<UUID>
}

struct HorizontalTabsSidebar: View {
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    var body: some View {
        let renderModel = workspaceRenderModel
        let selectedWorkspaceId = tabManager.selectedTabId

        HStack(spacing: 8) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")))
            .accessibilityLabel(Text(String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar")))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(renderModel.snapshots) { snapshot in
                            HorizontalWorkspaceTabItem(
                                snapshot: snapshot,
                                onSelect: {
                                    selectWorkspace(snapshot.id, renderModel: renderModel)
                                },
                                onClose: {
                                    closeWorkspace(snapshot.id, renderModel: renderModel)
                                },
                                onCopyWorkspaceID: {
                                    WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds([snapshot.id], includeRefs: false)
                                }
                            )
                            .id(snapshot.id)
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(maxHeight: .infinity)
                }
                .onAppear {
                    scrollToSelectedWorkspace(proxy, selectedWorkspaceId: selectedWorkspaceId)
                }
                .onChange(of: selectedWorkspaceId) { _, newValue in
                    scrollToSelectedWorkspace(proxy, selectedWorkspaceId: newValue)
                }
                .onChange(of: renderModel.renderedIds) { _, newRenderedIds in
                    reconcileSelectionWithRenderedOrder(renderedWorkspaceIds: newRenderedIds)
                    scrollToSelectedWorkspace(proxy, selectedWorkspaceId: tabManager.selectedTabId)
                }
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))
            .accessibilityLabel(Text(String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace")))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("Sidebar")
    }

    private var workspaceRenderModel: HorizontalWorkspaceTabRenderModel {
        let tabs = tabManager.tabs
        let workspaceCount = tabs.count
        let workspaceById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let groupsById = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0) })
        let renderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: groupsById
        )
        let shortcut = KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
        var snapshots: [HorizontalWorkspaceTabSnapshot] = []
        var renderedIds: [UUID] = []
        var renderedIndexById: [UUID: Int] = [:]
        var closeableIds: Set<UUID> = []
        snapshots.reserveCapacity(renderItems.count)
        renderedIds.reserveCapacity(renderItems.count)

        for item in renderItems {
            let snapshot: HorizontalWorkspaceTabSnapshot?
            switch item {
            case .groupHeader(let group, let memberWorkspaceIds):
                if let anchorWorkspace = workspaceById[group.anchorWorkspaceId] {
                    let anchorUnreadCount: Int
                    if group.isCollapsed {
                        anchorUnreadCount = memberWorkspaceIds.reduce(0) { partial, workspaceId in
                            partial + notificationStore.unreadCount(forTabId: workspaceId)
                        }
                    } else {
                        anchorUnreadCount = notificationStore.unreadCount(forTabId: group.anchorWorkspaceId)
                    }
                    snapshot = workspaceSnapshot(
                        workspace: anchorWorkspace,
                        title: group.name,
                        index: tabIndexById[group.anchorWorkspaceId] ?? 0,
                        workspaceCount: workspaceCount,
                        shortcut: shortcut,
                        isPinned: group.isPinned,
                        customColorHex: group.customColor ?? anchorWorkspace.customColor,
                        unreadCount: anchorUnreadCount
                    )
                } else {
                    snapshot = nil
                }
            case .workspace(let workspace):
                snapshot = workspaceSnapshot(
                    workspace: workspace,
                    title: workspace.title,
                    index: tabIndexById[workspace.id] ?? 0,
                    workspaceCount: workspaceCount,
                    shortcut: shortcut,
                    isPinned: workspace.isPinned,
                    customColorHex: workspace.customColor,
                    unreadCount: notificationStore.unreadCount(forTabId: workspace.id)
                )
            }

            guard let snapshot else { continue }
            snapshots.append(snapshot)
            renderedIndexById[snapshot.id] = renderedIds.count
            renderedIds.append(snapshot.id)
            if snapshot.canCloseWorkspace {
                closeableIds.insert(snapshot.id)
            }
        }

        return HorizontalWorkspaceTabRenderModel(
            snapshots: snapshots,
            renderedIds: renderedIds,
            renderedIndexById: renderedIndexById,
            workspaceById: workspaceById,
            closeableIds: closeableIds
        )
    }

    private func workspaceSnapshot(
        workspace: Workspace,
        title: String,
        index: Int,
        workspaceCount: Int,
        shortcut: StoredShortcut,
        isPinned: Bool,
        customColorHex: String?,
        unreadCount: Int
    ) -> HorizontalWorkspaceTabSnapshot {
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: index,
            workspaceCount: workspaceCount
        )
        let shortcutLabel = shortcutDigit.map { "\(shortcut.numberedDigitHintPrefix)\($0)" }
        return HorizontalWorkspaceTabSnapshot(
            id: workspace.id,
            title: title,
            isActive: tabManager.selectedTabId == workspace.id,
            isMultiSelected: selectedTabIds.contains(workspace.id),
            isPinned: isPinned,
            customColorHex: customColorHex,
            unreadCount: unreadCount,
            shortcutLabel: shortcutLabel,
            canCloseWorkspace: workspaceCount > 1 && tabManager.canCloseWorkspace(workspace, allowPinned: true),
            accessibilityTitle: String.localizedStringWithFormat(
                String(
                    localized: "accessibility.workspacePosition",
                    defaultValue: "%1$@, workspace %2$lld of %3$lld"
                ),
                title,
                Int64(index + 1),
                Int64(workspaceCount)
            )
        )
    }

    private func scrollToSelectedWorkspace(
        _ proxy: ScrollViewProxy,
        selectedWorkspaceId: UUID?
    ) {
        guard let selectedWorkspaceId else { return }
        proxy.scrollTo(selectedWorkspaceId)
    }

    private func selectWorkspace(
        _ workspaceId: UUID,
        renderModel: HorizontalWorkspaceTabRenderModel
    ) {
        let renderedWorkspaceIds = renderModel.renderedIds
        guard let index = renderModel.renderedIndexById[workspaceId],
              let workspace = renderModel.workspaceById[workspaceId] else {
            lastSidebarSelectionIndex = nil
            return
        }
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == workspaceId
        let validLastIndex = lastSidebarSelectionIndex.flatMap {
            renderedWorkspaceIds.indices.contains($0) ? $0 : nil
        }
        if lastSidebarSelectionIndex != nil, validLastIndex == nil {
            lastSidebarSelectionIndex = nil
        }

        if isShift, let lastIndex = validLastIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = Array(renderedWorkspaceIds[lower...upper])
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(workspaceId) {
                selectedTabIds.remove(workspaceId)
            } else {
                selectedTabIds.insert(workspaceId)
            }
        } else {
            selectedTabIds = [workspaceId]
        }

        lastSidebarSelectionIndex = index
        tabManager.selectTab(workspace)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: workspaceId,
                surfaceId: tabManager.focusedSurfaceId(for: workspaceId)
            )
        }
        selection = .tabs
    }

    private func closeWorkspace(
        _ workspaceId: UUID,
        renderModel: HorizontalWorkspaceTabRenderModel
    ) {
        guard renderModel.closeableIds.contains(workspaceId),
              let workspace = renderModel.workspaceById[workspaceId],
              tabManager.closeWorkspaceWithConfirmation(workspace) else { return }
        reconcileSelectionWithRenderedOrder()
    }

    private func reconcileSelectionWithRenderedOrder(renderedWorkspaceIds: [UUID]? = nil) {
        let liveRenderedIds = renderedWorkspaceIds ?? workspaceRenderModel.renderedIds
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy.reconciledSelection(
            previousSelectionIds: selectedTabIds,
            liveWorkspaceIds: liveRenderedIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        if selectedTabIds != nextSelectionIds {
            selectedTabIds = nextSelectionIds
        }
        let nextAnchorIndex = SidebarWorkspaceSelectionSyncPolicy.anchorIndex(
            preferredWorkspaceId: tabManager.selectedTabId,
            selectedWorkspaceIds: nextSelectionIds,
            liveWorkspaceIds: liveRenderedIds
        )
        if lastSidebarSelectionIndex != nextAnchorIndex {
            lastSidebarSelectionIndex = nextAnchorIndex
        }
    }
}

private struct HorizontalWorkspaceTabItem: View {
    let snapshot: HorizontalWorkspaceTabSnapshot
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCopyWorkspaceID: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private let tabWidth: CGFloat = 184
    private let tabHeight: CGFloat = 34

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    if let railColor {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3, height: 18)
                    }

                    if snapshot.unreadCount > 0 {
                        unreadBadge
                    }

                    if snapshot.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(secondaryTextColor)
                    }

                    Text(snapshot.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(primaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let shortcutLabel = snapshot.shortcutLabel {
                        ShortcutHintPill(text: shortcutLabel, fontSize: 9, emphasis: snapshot.isActive ? 1.0 : 0.75)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, snapshot.canCloseWorkspace && isHovering ? 27 : 10)
                .frame(width: tabWidth, height: tabHeight, alignment: .leading)
                .background(tabBackground)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .safeHelp(snapshot.title)
            .accessibilityLabel(Text(snapshot.accessibilityTitle))

            if snapshot.canCloseWorkspace && isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace"))
                .padding(.trailing, 6)
            }
        }
        .frame(width: tabWidth, height: tabHeight)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace")) {
                onClose()
            }
            .disabled(!snapshot.canCloseWorkspace)

            Button(String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID")) {
                onCopyWorkspaceID()
            }
        }
    }

    private var unreadBadge: some View {
        ZStack {
            Circle()
                .fill(snapshot.isActive ? primaryTextColor.opacity(0.25) : cmuxAccentColor())
            Text("\(min(snapshot.unreadCount, 99))")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(snapshot.isActive ? primaryTextColor : .white)
        }
        .frame(width: 15, height: 15)
    }

    private var tabBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: snapshot.isActive ? 1.2 : 1)
            }
    }

    private var backgroundColor: Color {
        if snapshot.isActive {
            return Color(nsColor: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme))
        }
        if snapshot.isMultiSelected {
            return Color.primary.opacity(0.11)
        }
        return Color.primary.opacity(isHovering ? 0.10 : 0.06)
    }

    private var borderColor: Color {
        if snapshot.isActive {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(
                on: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme),
                opacity: 0.36
            ))
        }
        return Color.primary.opacity(isHovering ? 0.12 : 0.08)
    }

    private var primaryTextColor: Color {
        if snapshot.isActive {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(
                on: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme),
                opacity: 1
            ))
        }
        return .primary
    }

    private var secondaryTextColor: Color {
        if snapshot.isActive {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(
                on: sidebarSelectedWorkspaceBackgroundNSColor(for: colorScheme),
                opacity: 0.78
            ))
        }
        return .secondary
    }

    private var railColor: Color? {
        guard let hex = snapshot.customColorHex,
              let nsColor = WorkspaceTabColorSettings.displayNSColor(
                hex: hex,
                colorScheme: colorScheme,
                forceBright: !snapshot.isActive
              ) ?? NSColor(hex: hex) else {
            return nil
        }
        return Color(nsColor: nsColor)
    }
}
