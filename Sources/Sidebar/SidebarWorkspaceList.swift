import AppKit
import Bonsplit
import SwiftUI

struct WorkspaceListRenderContext {
    let tabs: [Workspace]
    let groupingPlan: SidebarWorkspaceGroupingPlan
    let workspaceById: [UUID: Workspace]
    let workspaceCount: Int
    let canCloseWorkspace: Bool
    let workspaceNumberShortcut: StoredShortcut
    let tabItemSettings: SidebarTabItemSettingsSnapshot
    let tabIndexById: [UUID: Int]
    let selectedContextTargetIds: [UUID]
    let selectedRemoteContextMenuWorkspaceIds: [UUID]
    let allSelectedRemoteContextMenuTargetsConnecting: Bool
    let allSelectedRemoteContextMenuTargetsDisconnected: Bool
    let workspaceTerminalScrollBarHiddenById: [UUID: Bool]
    let folderGroups: [WorkspaceFolderRenderGroup]
    let renderedWorkspaceIds: [UUID]
    let workspaceOrderSignature: Int

    var workspaceIds: [UUID] {
        groupingPlan.bookmarkIds + folderGroups.flatMap { $0.plan.workspaceIds }
    }

    var groupIds: [String] {
        folderGroups.map(\.id)
    }

    func previousRenderedWorkspaceId(before workspaceId: UUID) -> UUID? {
        guard let index = renderedWorkspaceIds.firstIndex(of: workspaceId),
              index > 0 else {
            return nil
        }
        return renderedWorkspaceIds[index - 1]
    }
}

struct WorkspaceFolderRenderGroup: Identifiable {
    let plan: SidebarWorkspaceFolderGroup
    let tabs: [Workspace]

    var id: String { plan.id }
    var directory: String { plan.directory }
}

enum SidebarWorkspaceListRenderPolicy {
    static func folderGroups(
        groupingPlan: SidebarWorkspaceGroupingPlan,
        workspaceById: [UUID: Workspace]
    ) -> [WorkspaceFolderRenderGroup] {
        groupingPlan.folderGroups.compactMap { group in
            let tabs = group.workspaceIds.compactMap { workspaceById[$0] }
            guard !tabs.isEmpty else { return nil }
            return WorkspaceFolderRenderGroup(plan: group, tabs: tabs)
        }
    }

    static func renderedWorkspaceIds(
        bookmarkIds: [UUID],
        folderGroups: [WorkspaceFolderRenderGroup],
        collapsedGroupIds: Set<String>
    ) -> [UUID] {
        renderedWorkspaceIds(
            bookmarkIds: bookmarkIds,
            folderGroups: folderGroups.map(\.plan),
            collapsedGroupIds: collapsedGroupIds
        )
    }

    static func renderedWorkspaceIds(
        bookmarkIds: [UUID],
        folderGroups: [SidebarWorkspaceFolderGroup],
        collapsedGroupIds: Set<String>
    ) -> [UUID] {
        let showsFolderHeaders = showsFolderHeaders(folderGroups)
        return bookmarkIds + folderGroups.flatMap { group in
            showsFolderHeaders && collapsedGroupIds.contains(group.id) ? [] : group.workspaceIds
        }
    }

    static func showsFolderHeaders(_ folderGroups: [WorkspaceFolderRenderGroup]) -> Bool {
        folderGroups.count > 1
    }

    static func showsFolderHeaders(_ folderGroups: [SidebarWorkspaceFolderGroup]) -> Bool {
        folderGroups.count > 1
    }

    static func workspaceOrderSignature(
        visibleWorkspaceIds: [UUID],
        renderedWorkspaceIds: [UUID]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(visibleWorkspaceIds.count)
        for workspaceId in visibleWorkspaceIds {
            hasher.combine(workspaceId)
        }
        hasher.combine(renderedWorkspaceIds.count)
        for workspaceId in renderedWorkspaceIds {
            hasher.combine(workspaceId)
        }
        return hasher.finalize()
    }

    @MainActor
    static func groupingPlan(in tabManager: TabManager) -> SidebarWorkspaceGroupingPlan {
        SidebarWorkspaceGroupingPlanner.plan(
            for: tabManager.tabs.map {
                SidebarWorkspaceGroupingInput(
                    id: $0.id,
                    initialDirectory: $0.initialDirectory,
                    isPinned: $0.isPinned
                )
            }
        )
    }

    @MainActor
    static func renderedWorkspaceIds(
        in tabManager: TabManager,
        collapsedGroupIds: Set<String>
    ) -> [UUID] {
        let groupingPlan = groupingPlan(in: tabManager)
        return renderedWorkspaceIds(
            bookmarkIds: groupingPlan.bookmarkIds,
            folderGroups: groupingPlan.folderGroups,
            collapsedGroupIds: collapsedGroupIds
        )
    }

    @MainActor
    static func visibleWorkspaceIds(in tabManager: TabManager) -> [UUID] {
        groupingPlan(in: tabManager).visibleWorkspaceIds
    }
}

struct SidebarWorkspaceList<RowContent: View>: View {
    let renderContext: WorkspaceListRenderContext
    let rowSpacing: CGFloat
    @Binding var collapsedGroupIds: Set<String>
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onCreateWorkspaceInDirectory: (String) -> Void
    let onMoveBonsplitTabToExistingWorkspace: (UUID, BonsplitTabDragPayload.Transfer) -> Bool
    let onMoveBonsplitTabToNewWorkspace: (Int, BonsplitTabDragPayload.Transfer) -> UUID?
    let rowContent: (Workspace) -> RowContent

    init(
        renderContext: WorkspaceListRenderContext,
        rowSpacing: CGFloat,
        collapsedGroupIds: Binding<Set<String>>,
        tabManager: TabManager,
        draggedTabId: Binding<UUID?>,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        dragAutoScrollController: SidebarDragAutoScrollController,
        dropIndicator: Binding<SidebarDropIndicator?>,
        onCreateWorkspaceInDirectory: @escaping (String) -> Void,
        onMoveBonsplitTabToExistingWorkspace: @escaping (UUID, BonsplitTabDragPayload.Transfer) -> Bool,
        onMoveBonsplitTabToNewWorkspace: @escaping (Int, BonsplitTabDragPayload.Transfer) -> UUID?,
        @ViewBuilder rowContent: @escaping (Workspace) -> RowContent
    ) {
        self.renderContext = renderContext
        self.rowSpacing = rowSpacing
        self._collapsedGroupIds = collapsedGroupIds
        self.tabManager = tabManager
        self._draggedTabId = draggedTabId
        self._selectedTabIds = selectedTabIds
        self._lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self.dragAutoScrollController = dragAutoScrollController
        self._dropIndicator = dropIndicator
        self.onCreateWorkspaceInDirectory = onCreateWorkspaceInDirectory
        self.onMoveBonsplitTabToExistingWorkspace = onMoveBonsplitTabToExistingWorkspace
        self.onMoveBonsplitTabToNewWorkspace = onMoveBonsplitTabToNewWorkspace
        self.rowContent = rowContent
    }

    var body: some View {
        let bookmarkTabs = renderContext.groupingPlan.bookmarkIds.compactMap { renderContext.workspaceById[$0] }
        let folderGroups = renderContext.folderGroups
        let showsFolderHeaders = SidebarWorkspaceListRenderPolicy.showsFolderHeaders(folderGroups)

        return VStack(spacing: rowSpacing) {
            if !bookmarkTabs.isEmpty {
                SidebarBookmarkHeader(
                    count: bookmarkTabs.count,
                    tabManager: tabManager,
                    draggedTabId: $draggedTabId,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dragAutoScrollController: dragAutoScrollController,
                    dropIndicator: $dropIndicator,
                    renderedWorkspaceIdsForSelection: currentRenderedWorkspaceIds
                )
                ForEach(bookmarkTabs, id: \.id) { tab in
                    rowContent(tab)
                }
                if !folderGroups.isEmpty {
                    SidebarWorkspaceSectionDivider()
                }
            }

            ForEach(Array(folderGroups.enumerated()), id: \.element.id) { index, group in
                if showsFolderHeaders {
                    if index > 0 {
                        SidebarWorkspaceSectionDivider()
                    }
                    SidebarGroupHeader(
                        directory: group.directory,
                        count: group.tabs.count,
                        isCollapsed: collapsedGroupIds.contains(group.id),
                        onToggle: {
                            withAnimation(.easeOut(duration: 0.1)) {
                                toggleCollapsedGroup(group)
                            }
                        },
                        tabManager: tabManager,
                        draggedTabId: $draggedTabId,
                        selectedTabIds: $selectedTabIds,
                        lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                        dragAutoScrollController: dragAutoScrollController,
                        dropIndicator: $dropIndicator,
                        renderedWorkspaceIdsForSelection: currentRenderedWorkspaceIds,
                        onDropWorkspace: {
                            collapsedGroupIds.remove(group.id)
                        }
                    )
                }

                if !showsFolderHeaders || !collapsedGroupIds.contains(group.id) {
                    ForEach(group.tabs, id: \.id) { tab in
                        rowContent(tab)
                    }
                }
            }

            SidebarAddFolderButton(onSelectDirectory: onCreateWorkspaceInDirectory)
        }
        .padding(.vertical, SidebarWorkspaceListMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayPreferenceValue(SidebarWorkspaceRowFramePreferenceKey.self) { anchors in
            GeometryReader { proxy in
                SidebarBonsplitTabWorkspaceDropOverlay(
                    currentSelectedTabId: {
                        tabManager.selectedTabId
                    },
                    sidebarIndexForTabId: { workspaceId in
                        renderContext.renderedWorkspaceIds.firstIndex(of: workspaceId)
                    },
                    moveToExistingWorkspace: onMoveBonsplitTabToExistingWorkspace,
                    moveToNewWorkspace: onMoveBonsplitTabToNewWorkspace,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: $dropIndicator,
                    updateAutoscroll: {
                        dragAutoScrollController.updateFromDragLocation()
                    },
                    targets: renderContext.renderedWorkspaceIds.compactMap { workspaceId in
                        guard let tab = renderContext.workspaceById[workspaceId],
                              let anchor = anchors[workspaceId] else { return nil }
                        return SidebarDropPlanner.WorkspaceDropTarget(
                            workspaceId: tab.id,
                            isPinned: tab.isPinned,
                            frame: proxy[anchor]
                        )
                    }
                )
            }
        }
    }

    private func toggleCollapsedGroup(_ group: WorkspaceFolderRenderGroup) {
        if collapsedGroupIds.contains(group.id) {
            collapsedGroupIds.remove(group.id)
            return
        }
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              group.plan.workspaceIds.contains(selectedWorkspaceId) else {
            collapsedGroupIds.insert(group.id)
            return
        }
        collapsedGroupIds.remove(group.id)
    }

    @MainActor
    private func currentRenderedWorkspaceIds() -> [UUID] {
        SidebarWorkspaceListRenderPolicy.renderedWorkspaceIds(
            in: tabManager,
            collapsedGroupIds: collapsedGroupIds
        )
    }
}

private struct SidebarWorkspaceSectionDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }
}

private struct SidebarBookmarkHeader: View {
    let count: Int
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let renderedWorkspaceIdsForSelection: @MainActor () -> [UUID]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(String(localized: "sidebar.bookmarks.title", defaultValue: "BOOKMARKS"))
                .font(.system(size: 10, weight: .bold))
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarBookmarkHeaderDropDelegate(
            tabManager: tabManager,
            draggedTabId: $draggedTabId,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator,
            renderedWorkspaceIdsForSelection: renderedWorkspaceIdsForSelection
        ))
    }
}

private struct SidebarGroupHeader: View {
    let directory: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let renderedWorkspaceIdsForSelection: @MainActor () -> [UUID]
    let onDropWorkspace: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(SidebarPathFormatter.shortenedPath(directory))
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isCollapsed {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(directory)
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarGroupHeaderDropDelegate(
            directory: directory,
            tabManager: tabManager,
            draggedTabId: $draggedTabId,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator,
            renderedWorkspaceIdsForSelection: renderedWorkspaceIdsForSelection,
            onDropWorkspace: onDropWorkspace
        ))
    }
}

private struct SidebarAddFolderButton: View {
    let onSelectDirectory: (String) -> Void

    var body: some View {
        Button(action: openFolderPicker) {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                Text(String(localized: "sidebar.addFolder.button", defaultValue: "Add Folder"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(String(localized: "sidebar.addFolder.tooltip", defaultValue: "Open a folder in a new workspace"))
        .accessibilityIdentifier("SidebarAddFolderButton")
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "sidebar.addFolder.panelTitle", defaultValue: "Add Folder")
        panel.prompt = String(localized: "sidebar.addFolder.panelPrompt", defaultValue: "Add")
        if panel.runModal() == .OK, let url = panel.url {
            onSelectDirectory(url.path)
        }
    }
}

struct SidebarWorkspaceRowIdsPreferenceKey: PreferenceKey {
    static let defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}

struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct SidebarGroupHeaderDropDelegate: DropDelegate {
    let directory: String
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let renderedWorkspaceIdsForSelection: @MainActor () -> [UUID]
    let onDropWorkspace: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]) && draggedTabId != nil
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        dropIndicator = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        dropIndicator = nil
        return validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard validateDrop(info: info), let draggedTabId else { return false }
        guard tabManager.moveWorkspaceToInitialDirectoryGroupEnd(
            tabId: draggedTabId,
            directory: directory
        ) else {
            return false
        }
        onDropWorkspace()
        selectedTabIds = [draggedTabId]
        syncSidebarSelection(preferredSelectedTabId: draggedTabId)
        return true
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = renderedWorkspaceIdsForSelection().firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

private struct SidebarBookmarkHeaderDropDelegate: DropDelegate {
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let renderedWorkspaceIdsForSelection: @MainActor () -> [UUID]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier]) && draggedTabId != nil
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        dropIndicator = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        dropIndicator = nil
        return validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard validateDrop(info: info), let draggedTabId else { return false }
        guard tabManager.moveWorkspaceToBookmarksEnd(tabId: draggedTabId) else { return false }
        selectedTabIds = [draggedTabId]
        syncSidebarSelection(preferredSelectedTabId: draggedTabId)
        return true
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = renderedWorkspaceIdsForSelection().firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }
}

struct SidebarTabDropDelegate: DropDelegate {
    let targetTabId: UUID?
    let tabManager: TabManager
    @Binding var draggedTabId: UUID?
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let targetRowHeight: CGFloat?
    let planningTabIds: @MainActor () -> [UUID]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?

    func validateDrop(info: DropInfo) -> Bool {
        let hasType = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let hasDrag = draggedTabId != nil
        #if DEBUG
        cmuxDebugLog("sidebar.validateDrop target=\(targetTabId?.uuidString.prefix(5) ?? "end") hasType=\(hasType) hasDrag=\(hasDrag)")
        #endif
        return hasType && hasDrag
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        cmuxDebugLog("sidebar.dropEntered target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropExited target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
#endif
        if dropIndicator?.tabId == targetTabId {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator(for: info)
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropUpdated target=\(targetTabId?.uuidString.prefix(5) ?? "end") " +
            "indicator=\(debugIndicator(dropIndicator))"
        )
#endif
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        #if DEBUG
        cmuxDebugLog("sidebar.drop target=\(targetTabId?.uuidString.prefix(5) ?? "end")")
        #endif
        guard let draggedTabId else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=missingDraggedTab")
#endif
            return false
        }
        let tabIds = planningTabIds()
        guard let fromIndex = tabIds.firstIndex(of: draggedTabId),
              let draggedWorkspace = tabManager.tabs.first(where: { $0.id == draggedTabId }) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=draggedTabMissing tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }
        let targetInitialDirectory: String? = targetTabId.flatMap { targetTabId in
            guard let targetWorkspace = tabManager.tabs.first(where: { $0.id == targetTabId }),
                  !targetWorkspace.isPinned else {
                return nil
            }
            return targetWorkspace.initialDirectory
        }
        let moveInitialDirectory = draggedWorkspace.isPinned ? nil : targetInitialDirectory
        let changesInitialDirectory = moveInitialDirectory.map { draggedWorkspace.initialDirectory != $0 } ?? false
        let plannedTargetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            indicator: dropIndicator,
            tabIds: tabIds,
            pinnedTabIds: Set(tabManager.tabs.filter(\.isPinned).map(\.id))
        )
        guard let targetIndex = plannedTargetIndex ?? (changesInitialDirectory ? fromIndex : nil) else {
#if DEBUG
            cmuxDebugLog(
                "sidebar.drop.abort reason=noTargetIndex tab=\(draggedTabId.uuidString.prefix(5)) " +
                "target=\(targetTabId?.uuidString.prefix(5) ?? "end") indicator=\(debugIndicator(dropIndicator))"
            )
#endif
            return false
        }

        guard tabManager.moveWorkspaceInSidebarVisualOrder(
            tabId: draggedTabId,
            toVisibleIndex: targetIndex,
            initialDirectory: moveInitialDirectory
        ) else {
#if DEBUG
            cmuxDebugLog("sidebar.drop.abort reason=moveFailed tab=\(draggedTabId.uuidString.prefix(5))")
#endif
            return false
        }

#if DEBUG
        cmuxDebugLog(
            "sidebar.drop.commit tab=\(draggedTabId.uuidString.prefix(5)) " +
            "from=\(fromIndex) to=\(targetIndex) groupChanged=\(changesInitialDirectory ? 1 : 0)"
        )
#endif
        if let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
            syncSidebarSelection(preferredSelectedTabId: selectedId)
        } else {
            selectedTabIds = []
            syncSidebarSelection()
        }
        return true
    }

    private func updateDropIndicator(for info: DropInfo) {
        let tabIds = planningTabIds()
        let pinnedTabIds = Set(tabManager.tabs.filter(\.isPinned).map(\.id))
        let nextIndicator = SidebarDropPlanner.indicator(
            draggedTabId: draggedTabId,
            targetTabId: targetTabId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: targetTabId == nil ? nil : info.location.y,
            targetHeight: targetRowHeight
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func syncSidebarSelection(preferredSelectedTabId: UUID? = nil) {
        let selectedId = preferredSelectedTabId ?? tabManager.selectedTabId
        if let selectedId {
            lastSidebarSelectionIndex = planningTabIds().firstIndex(of: selectedId)
        } else {
            lastSidebarSelectionIndex = nil
        }
    }

    private func debugIndicator(_ indicator: SidebarDropIndicator?) -> String {
        guard let indicator else { return "nil" }
        let tabText = indicator.tabId.map { String($0.uuidString.prefix(5)) } ?? "end"
        return "\(tabText):\(indicator.edge == .top ? "top" : "bottom")"
    }
}

@MainActor
func sidebarVisualIndex(of workspaceId: UUID, in tabManager: TabManager) -> Int? {
    SidebarWorkspaceListRenderPolicy.visibleWorkspaceIds(in: tabManager).firstIndex(of: workspaceId)
}

@MainActor
func sidebarVisibleWorkspaceIds(in tabManager: TabManager) -> [UUID] {
    SidebarWorkspaceListRenderPolicy.visibleWorkspaceIds(in: tabManager)
}
