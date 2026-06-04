import AppKit
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

struct HorizontalTabsSidebar: View {
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore

    var body: some View {
        let snapshots = workspaceSnapshots
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
                        ForEach(snapshots) { snapshot in
                            HorizontalWorkspaceTabItem(
                                snapshot: snapshot,
                                onSelect: {
                                    selectWorkspace(snapshot.id)
                                },
                                onClose: {
                                    closeWorkspace(snapshot.id)
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
                .onChange(of: snapshots.map(\.id)) { _, _ in
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

    private var workspaceSnapshots: [HorizontalWorkspaceTabSnapshot] {
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
        return renderItems.compactMap { item in
            switch item {
            case .groupHeader(let group, let memberWorkspaceIds):
                guard let anchorWorkspace = workspaceById[group.anchorWorkspaceId] else { return nil }
                let anchorUnreadCount: Int
                if group.isCollapsed {
                    anchorUnreadCount = memberWorkspaceIds.reduce(0) { partial, workspaceId in
                        partial + notificationStore.unreadCount(forTabId: workspaceId)
                    }
                } else {
                    anchorUnreadCount = notificationStore.unreadCount(forTabId: group.anchorWorkspaceId)
                }
                return workspaceSnapshot(
                    workspace: anchorWorkspace,
                    title: group.name,
                    index: tabIndexById[group.anchorWorkspaceId] ?? 0,
                    workspaceCount: workspaceCount,
                    shortcut: shortcut,
                    isPinned: group.isPinned,
                    customColorHex: group.customColor ?? anchorWorkspace.customColor,
                    unreadCount: anchorUnreadCount
                )
            case .workspace(let workspace):
                return workspaceSnapshot(
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
        }
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
            canCloseWorkspace: workspaceCount > 1,
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

    private func selectWorkspace(_ workspaceId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = tabManager.tabs[index]
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == workspaceId

        if isShift, let lastIndex = lastSidebarSelectionIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = tabManager.tabs[lower...upper].map(\.id)
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

    private func closeWorkspace(_ workspaceId: UUID) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        tabManager.closeWorkspaceWithConfirmation(workspace)
        let existingIds = Set(tabManager.tabs.map(\.id))
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }
}

private struct HorizontalWorkspaceTabItem: View, Equatable {
    static func == (lhs: HorizontalWorkspaceTabItem, rhs: HorizontalWorkspaceTabItem) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

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
