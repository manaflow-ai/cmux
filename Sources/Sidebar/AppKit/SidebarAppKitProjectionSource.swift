import AppKit
import Combine
import CmuxCore
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Main-actor projection boundary for the native workspace sidebar.
///
/// Structural publishers are observed once for the whole table. Row-affecting
/// workspace publishers are observed only while a workspace is visible. This
/// keeps the number of long-lived tasks proportional to reusable table cells,
/// rather than the total number of workspaces.
@MainActor
final class SidebarAppKitProjectionSource {
    private struct GroupAggregate {
        var totalUnreadCount = 0
        var nonAnchorMemberCount = 0
        var unreadNonAnchorMemberCount = 0
    }

    struct Change {
        let structureChanged: Bool
        let itemIds: Set<SidebarWorkspaceRenderItemID>
        let selectionChanged: Bool

        static let structure = Change(
            structureChanged: true,
            itemIds: [],
            selectionChanged: true
        )

        static func rows(
            _ itemIds: Set<SidebarWorkspaceRenderItemID>,
            selectionChanged: Bool = false
        ) -> Change {
            Change(
                structureChanged: false,
                itemIds: itemIds,
                selectionChanged: selectionChanged
            )
        }
    }

    private let tabManager: TabManager
    private let sidebarUnread: SidebarUnreadModel
    private let cmuxConfigStore: CmuxConfigStore
    private let notificationStore: TerminalNotificationStore
    private let onWorkspaceProjection: () -> Void

    private var tabs: [Workspace]
    private var groups: [WorkspaceGroup]
    private var selectedWorkspaceId: UUID?
    private var selectedWorkspaceIds: Set<UUID>
    private var unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    private var settings: SidebarTabItemSettingsSnapshot
    private var showsAgentActivity: Bool
    private var showsModifierShortcutHints: Bool
    private var expandedChecklistWorkspaceIds: Set<UUID> = []

    private(set) var renderItems: [SidebarWorkspaceRenderItem] = []
    private(set) var workspaceById: [UUID: Workspace] = [:]
    private(set) var workspaceIndexById: [UUID: Int] = [:]
    private(set) var groupById: [UUID: WorkspaceGroup] = [:]
    private(set) var memberWorkspaceIdsByGroupId: [UUID: [UUID]] = [:]
    private var groupAggregateById: [UUID: GroupAggregate] = [:]

    private var detailSnapshotByWorkspaceId: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    private var visibleWorkspaceIds: Set<UUID> = []
    private var visibleObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var modelObservationTasks: [Task<Void, Never>] = []
    private var unreadSummaryChangesCancellable: AnyCancellable?
    private var settingsObservers: [NSObjectProtocol] = []
    private var sidebarFontSize: CGFloat

    var onChange: ((Change) -> Void)?

    init(
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        cmuxConfigStore: CmuxConfigStore,
        notificationStore: TerminalNotificationStore = .shared,
        selectedWorkspaceIds: Set<UUID>,
        showsAgentActivity: Bool,
        showsModifierShortcutHints: Bool = false,
        onWorkspaceProjection: @escaping () -> Void = {}
    ) {
        self.tabManager = tabManager
        self.sidebarUnread = sidebarUnread
        self.cmuxConfigStore = cmuxConfigStore
        self.notificationStore = notificationStore
        self.onWorkspaceProjection = onWorkspaceProjection
        tabs = tabManager.tabs
        groups = tabManager.workspaceGroups
        selectedWorkspaceId = tabManager.selectedTabId
        self.selectedWorkspaceIds = selectedWorkspaceIds
        unreadSummariesByWorkspaceId = sidebarUnread.summaryByWorkspaceId
        sidebarFontSize = GhosttyConfig.load().sidebarFontSize
        settings = SidebarTabItemSettingsSnapshot(sidebarFontSize: sidebarFontSize)
        self.showsAgentActivity = showsAgentActivity
        self.showsModifierShortcutHints = showsModifierShortcutHints
        rebuildStructure(notify: false)
        startModelObservations()
        startSettingsObservations()
    }

    deinit {
        for task in modelObservationTasks { task.cancel() }
        for task in visibleObservationTasks.values { task.cancel() }
        unreadSummaryChangesCancellable?.cancel()
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func emitCurrentState() {
        onChange?(.structure)
    }

    func updateExternalState(
        selectedWorkspaceIds: Set<UUID>,
        showsAgentActivity: Bool,
        showsModifierShortcutHints: Bool? = nil
    ) {
        var changedIds: Set<SidebarWorkspaceRenderItemID> = []
        var selectionChanged = false
        if self.selectedWorkspaceIds != selectedWorkspaceIds {
            selectionChanged = true
            changedIds = changedSelectionItemIds(
                from: self.selectedWorkspaceIds,
                to: selectedWorkspaceIds
            )
            self.selectedWorkspaceIds = selectedWorkspaceIds
        }

        if self.showsAgentActivity != showsAgentActivity {
            self.showsAgentActivity = showsAgentActivity
            detailSnapshotByWorkspaceId.removeAll(keepingCapacity: true)
            changedIds.formUnion(visibleWorkspaceIds.map(SidebarWorkspaceRenderItemID.workspace))
        }
        if let showsModifierShortcutHints,
           self.showsModifierShortcutHints != showsModifierShortcutHints {
            self.showsModifierShortcutHints = showsModifierShortcutHints
            changedIds.formUnion(visibleWorkspaceIds.map {
                renderItemId(forWorkspaceId: $0)
            })
        }
        publishRows(changedIds, selectionChanged: selectionChanged)
    }

    func setVisibleWorkspaceIds(_ ids: Set<UUID>) {
        let liveVisibleIds = Set(ids.filter { workspaceById[$0] != nil })
        guard liveVisibleIds != visibleWorkspaceIds else { return }

        let removedIds = visibleWorkspaceIds.subtracting(liveVisibleIds)
        let addedIds = liveVisibleIds.subtracting(visibleWorkspaceIds)
        visibleWorkspaceIds = liveVisibleIds

        for id in removedIds {
            visibleObservationTasks.removeValue(forKey: id)?.cancel()
        }
        for id in addedIds {
            guard let workspace = workspaceById[id] else { continue }
            visibleObservationTasks[id] = observeVisibleWorkspace(workspace)
        }
    }

    func setChecklistExpanded(_ isExpanded: Bool, workspaceId: UUID) {
        guard workspaceById[workspaceId] != nil else { return }
        let changed: Bool
        if isExpanded {
            changed = expandedChecklistWorkspaceIds.insert(workspaceId).inserted
        } else {
            changed = expandedChecklistWorkspaceIds.remove(workspaceId) != nil
        }
        guard changed else { return }
        publishRows([renderItemId(forWorkspaceId: workspaceId)])
    }

    func isChecklistExpanded(workspaceId: UUID) -> Bool {
        expandedChecklistWorkspaceIds.contains(workspaceId)
    }

    func collapseAllChecklists() {
        guard !expandedChecklistWorkspaceIds.isEmpty else { return }
        let itemIds = Set(expandedChecklistWorkspaceIds.map(renderItemId(forWorkspaceId:)))
        expandedChecklistWorkspaceIds.removeAll(keepingCapacity: true)
        publishRows(itemIds)
    }

    func workspaceSnapshot(workspaceId: UUID) -> SidebarWorkspaceRowSnapshot? {
        guard let workspace = workspaceById[workspaceId],
              let index = workspaceIndexById[workspaceId] else {
            return nil
        }
        onWorkspaceProjection()
        let detail = detailSnapshot(for: workspace)
        let unread = unreadSummariesByWorkspaceId[workspaceId]
            ?? SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
        let todoResolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: workspace.todoState.statusOverride,
            inferred: workspace.inferredTaskStatus
        )
        let activeTodoOverride: WorkspaceTaskStatus? = {
            guard let override = workspace.todoState.statusOverride,
                  !todoResolution.shouldClearOverride else {
                return nil
            }
            return override.status
        }()
        // Native menus resolve their complete target aggregate only when the
        // menu opens. The cell snapshot carries a constant-size placeholder so
        // realizing one row never scans the selected set, all groups, all live
        // workspace ids, or the notification collection.
        let contextMenu = SidebarWorkspaceContextMenuSnapshot(
            targetWorkspaceIds: [workspaceId],
            remoteTargetWorkspaceIds: [],
            allRemoteTargetsConnecting: false,
            allRemoteTargetsDisconnected: false,
            pinState: nil,
            groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: selectedWorkspaceId.flatMap { workspaceById[$0] }?.isRemoteTmuxMirror != true,
            eligibleGroupTargetIds: [],
            allEligibleTargetsGroupId: nil,
            hasGroupedEligibleTarget: false,
            todoStatusLanes: WorkspaceTodoStatusLane.lanes(
                inferred: workspace.inferredTaskStatus,
                activeOverride: activeTodoOverride,
                isHidden: workspace.todoState.statusHidden
            ),
            canMarkRead: unread.unreadCount > 0,
            canMarkUnread: unread.unreadCount == 0,
            // Native menus resolve notifications when the menu opens. Keeping
            // them out of every visible-cell snapshot avoids sorting/copying
            // menu payloads during scroll and hover.
            hasLatestNotification: false,
            notifications: []
        )

        return SidebarWorkspaceRowSnapshot(
            workspaceId: workspaceId,
            groupId: workspace.groupId,
            index: index,
            workspaceCount: tabs.count,
            workspace: detail,
            isActive: selectedWorkspaceId == workspaceId,
            isMultiSelected: selectedWorkspaceIds.contains(workspaceId),
            hasUserCustomTitle: workspace.effectiveCustomTitleSource == .user,
            hasCustomTitle: workspace.hasCustomTitle,
            hasCustomDescription: workspace.hasCustomDescription,
            customTitle: workspace.customTitle,
            workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: index,
                workspaceCount: tabs.count
            ),
            workspaceShortcutModifierSymbol: KeyboardShortcutSettings
                .shortcut(for: .selectWorkspaceByNumber)
                .numberedDigitHintPrefix,
            canCloseWorkspace: tabs.count > 1,
            unreadCount: unread.unreadCount,
            latestNotificationText: settings.showsNotificationMessage
                ? unread.latestNotificationText
                : nil,
            showsAgentActivity: showsAgentActivity,
            rowSpacing: 2,
            showsModifierShortcutHints: showsModifierShortcutHints,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: expandedChecklistWorkspaceIds.contains(workspaceId),
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: contextMenu
        )
    }

    func groupSnapshot(groupId: UUID) -> SidebarWorkspaceGroupRowSnapshot? {
        guard let group = groupById[groupId] else { return nil }
        let memberIds = memberWorkspaceIdsByGroupId[groupId] ?? []
        let anchorIndex = workspaceIndexById[group.anchorWorkspaceId] ?? 0
        let anchorCwd = workspaceById[group.anchorWorkspaceId]?.currentDirectory
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)
        let aggregate = groupAggregateById[groupId] ?? GroupAggregate()
        let anchorUnreadCount: Int
        if group.isCollapsed {
            anchorUnreadCount = aggregate.totalUnreadCount
        } else {
            anchorUnreadCount = unreadSummariesByWorkspaceId[group.anchorWorkspaceId]?.unreadCount ?? 0
        }

        return SidebarWorkspaceGroupRowSnapshot(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
                explicit: group.iconSymbol,
                configured: resolvedConfig?.iconSymbol
            ),
            tintHex: group.customColor ?? resolvedConfig?.color,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: selectedWorkspaceId == group.anchorWorkspaceId,
            memberCount: memberIds.count,
            anchorUnreadCount: anchorUnreadCount,
            canMarkRead: (unreadSummariesByWorkspaceId[group.anchorWorkspaceId]?.unreadCount ?? 0) > 0,
            canMarkUnread: (unreadSummariesByWorkspaceId[group.anchorWorkspaceId]?.unreadCount ?? 0) == 0,
            hasLatestNotifications: notificationStore.latestNotification(forTabId: group.anchorWorkspaceId) != nil,
            canMarkAllRead: aggregate.unreadNonAnchorMemberCount > 0,
            canMarkAllUnread: aggregate.unreadNonAnchorMemberCount
                < aggregate.nonAnchorMemberCount,
            shortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                at: anchorIndex,
                workspaceCount: tabs.count
            ),
            shortcutModifierSymbol: KeyboardShortcutSettings
                .shortcut(for: .selectWorkspaceByNumber)
                .numberedDigitHintPrefix,
            showsShortcutHint: showsModifierShortcutHints,
            isPointerHovering: false,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            cwdContextMenuItems: resolvedConfig?.contextMenuItems ?? [],
            newWorkspacePlacement: resolvedConfig?.newWorkspacePlacement,
            rowSpacing: 2,
            isFirstRow: renderItems.first?.rowWorkspaceId == group.anchorWorkspaceId,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            shouldCollectWorkspaceDropTargets: false
        )
    }

    func contextTargetWorkspaceIds(for workspaceId: UUID) -> [UUID] {
        guard selectedWorkspaceIds.contains(workspaceId) else { return [workspaceId] }
        return tabs.compactMap { selectedWorkspaceIds.contains($0.id) ? $0.id : nil }
    }

    private func startModelObservations() {
        unreadSummaryChangesCancellable = sidebarUnread.summaryChangesPublisher.sink {
            [weak self] changes in
            MainActor.assumeIsolated {
                self?.receiveUnreadSummaryChanges(changes)
            }
        }
        modelObservationTasks = [
            Task { @MainActor [weak self, tabManager] in
                for await nextTabs in tabManager.tabsPublisher.values {
                    guard !Task.isCancelled, let self else { return }
                    receiveTabs(nextTabs)
                }
            },
            Task { @MainActor [weak self, tabManager] in
                for await nextGroups in tabManager.workspaceGroupsPublisher.values {
                    guard !Task.isCancelled, let self else { return }
                    receiveGroups(nextGroups)
                }
            },
            Task { @MainActor [weak self, tabManager] in
                for await nextSelectedId in tabManager.selectedTabIdPublisher.values {
                    guard !Task.isCancelled, let self else { return }
                    receiveSelectedWorkspaceId(nextSelectedId)
                }
            },
            Task { @MainActor [weak self, cmuxConfigStore] in
                for await _ in cmuxConfigStore.$workspaceGroupConfigs.values {
                    guard !Task.isCancelled, let self else { return }
                    publishRows(Set(groups.map {
                        SidebarWorkspaceRenderItemID.group($0.id)
                    }))
                }
            },
        ]
    }

    private func startSettingsObservations() {
        let defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSettings() }
        }
        let ghosttyObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                sidebarFontSize = GhosttyConfig.load().sidebarFontSize
                refreshSettings()
            }
        }
        settingsObservers = [defaultsObserver, ghosttyObserver]
    }

    private func receiveTabs(_ nextTabs: [Workspace]) {
        let previousWorkspaceById = Dictionary(
            tabs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldIds = tabs.map(\.id)
        let nextIds = nextTabs.map(\.id)
        let oldGroupIds = tabs.map(\.groupId)
        let nextGroupIds = nextTabs.map(\.groupId)
        let replacedWorkspaceIds = nextTabs.compactMap { next in
            guard let previous = previousWorkspaceById[next.id], previous !== next else {
                return nil
            }
            return next.id
        }
        tabs = nextTabs
        if !replacedWorkspaceIds.isEmpty {
            for id in replacedWorkspaceIds { detailSnapshotByWorkspaceId[id] = nil }
        }
        guard oldIds != nextIds || oldGroupIds != nextGroupIds || !replacedWorkspaceIds.isEmpty else {
            return
        }
        rebuildStructure(
            notify: true,
            replacedWorkspaceIds: Set(replacedWorkspaceIds)
        )
    }

    private func receiveGroups(_ nextGroups: [WorkspaceGroup]) {
        guard groups != nextGroups else { return }
        groups = nextGroups
        rebuildStructure(notify: true)
    }

    private func receiveSelectedWorkspaceId(_ nextId: UUID?) {
        guard selectedWorkspaceId != nextId else { return }
        let previousId = selectedWorkspaceId
        selectedWorkspaceId = nextId
        var ids: Set<SidebarWorkspaceRenderItemID> = []
        if let previousId { ids.insert(renderItemId(forWorkspaceId: previousId)) }
        if let nextId { ids.insert(renderItemId(forWorkspaceId: nextId)) }
        publishRows(ids)
    }

    private func receiveUnreadSummaryChanges(
        _ changes: [SidebarWorkspaceUnreadSummaryChange]
    ) {
        guard !changes.isEmpty else { return }
        var itemIds = Set<SidebarWorkspaceRenderItemID>()
        itemIds.reserveCapacity(changes.count * 2)
        for change in changes {
            let workspaceId = change.workspaceId
            let previous = unreadSummariesByWorkspaceId[workspaceId]
            guard previous != change.summary else { continue }
            if let summary = change.summary {
                unreadSummariesByWorkspaceId[workspaceId] = summary
            } else {
                unreadSummariesByWorkspaceId.removeValue(forKey: workspaceId)
            }
            updateGroupAggregate(
                workspaceId: workspaceId,
                previous: previous,
                next: change.summary
            )
            itemIds.insert(.workspace(workspaceId))
            if let groupId = workspaceById[workspaceId]?.groupId {
                itemIds.insert(.group(groupId))
            }
        }
        publishRows(itemIds)
    }

    private func rebuildStructure(
        notify: Bool,
        replacedWorkspaceIds: Set<UUID> = []
    ) {
        let liveIds = Set(tabs.map(\.id))
        workspaceById = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        workspaceIndexById = Dictionary(
            tabs.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        groupById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        memberWorkspaceIdsByGroupId = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(tabs: tabs)
        rebuildGroupAggregates()
        renderItems = SidebarWorkspaceRenderItem.renderItems(tabs: tabs, groupsById: groupById)
        detailSnapshotByWorkspaceId = detailSnapshotByWorkspaceId.filter { liveIds.contains($0.key) }
        expandedChecklistWorkspaceIds.formIntersection(liveIds)
        setVisibleWorkspaceIds(visibleWorkspaceIds)
        restartVisibleObservations(for: replacedWorkspaceIds)
        if notify { onChange?(.structure) }
    }

    /// A structural publisher may replace a `Workspace` reference without
    /// changing its stable id. Visible observation tasks capture the reference,
    /// so transfer those tasks to the replacement instead of treating the
    /// unchanged visible-id set as a no-op.
    private func restartVisibleObservations(for workspaceIds: Set<UUID>) {
        for workspaceId in workspaceIds where visibleWorkspaceIds.contains(workspaceId) {
            visibleObservationTasks.removeValue(forKey: workspaceId)?.cancel()
            guard let workspace = workspaceById[workspaceId] else { continue }
            visibleObservationTasks[workspaceId] = observeVisibleWorkspace(workspace)
        }
    }

    private func rebuildGroupAggregates() {
        var next: [UUID: GroupAggregate] = [:]
        next.reserveCapacity(groups.count)
        for group in groups {
            let memberIds = memberWorkspaceIdsByGroupId[group.id] ?? []
            var aggregate = GroupAggregate()
            aggregate.nonAnchorMemberCount = memberIds.reduce(into: 0) { count, workspaceId in
                if workspaceId != group.anchorWorkspaceId {
                    count += 1
                }
            }
            for workspaceId in memberIds {
                let unreadCount = unreadSummariesByWorkspaceId[workspaceId]?.unreadCount ?? 0
                aggregate.totalUnreadCount += unreadCount
                if workspaceId != group.anchorWorkspaceId, unreadCount > 0 {
                    aggregate.unreadNonAnchorMemberCount += 1
                }
            }
            next[group.id] = aggregate
        }
        groupAggregateById = next
    }

    private func updateGroupAggregate(
        workspaceId: UUID,
        previous: SidebarWorkspaceUnreadSummary?,
        next: SidebarWorkspaceUnreadSummary?
    ) {
        guard let groupId = workspaceById[workspaceId]?.groupId,
              let group = groupById[groupId],
              var aggregate = groupAggregateById[groupId] else {
            return
        }
        let previousCount = previous?.unreadCount ?? 0
        let nextCount = next?.unreadCount ?? 0
        aggregate.totalUnreadCount += nextCount - previousCount
        if workspaceId != group.anchorWorkspaceId {
            if previousCount == 0, nextCount > 0 {
                aggregate.unreadNonAnchorMemberCount += 1
            } else if previousCount > 0, nextCount == 0 {
                aggregate.unreadNonAnchorMemberCount -= 1
            }
        }
        groupAggregateById[groupId] = aggregate
    }

    private func observeVisibleWorkspace(_ workspace: Workspace) -> Task<Void, Never> {
        let id = workspace.id
        return Task { @MainActor [weak self, weak workspace] in
            guard let workspace else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor [weak self, weak workspace] in
                    guard let workspace else { return }
                    for await _ in workspace.sidebarImmediateObservationPublisher.values {
                        guard !Task.isCancelled, let self else { return }
                        invalidateDetail(workspaceId: id)
                    }
                }
                group.addTask { @MainActor [weak self, weak workspace] in
                    guard let workspace else { return }
                    for await _ in workspace.sidebarObservationPublisher.values {
                        guard !Task.isCancelled, let self else { return }
                        invalidateDetail(workspaceId: id)
                    }
                }
                group.addTask { @MainActor [weak self, weak workspace] in
                    guard let workspace else { return }
                    for await _ in workspace.sidebarProcessTitleObservation.changes() {
                        guard !Task.isCancelled, let self else { return }
                        invalidateDetail(workspaceId: id)
                    }
                }
                group.addTask { @MainActor [weak self, weak workspace] in
                    guard let workspace else { return }
                    for await _ in workspace.sidebarAgentRuntimeObservation.changes() {
                        guard !Task.isCancelled, let self else { return }
                        invalidateDetail(workspaceId: id)
                    }
                }
            }
        }
    }

    private func invalidateDetail(workspaceId: UUID) {
        detailSnapshotByWorkspaceId[workspaceId] = nil
        var ids: Set<SidebarWorkspaceRenderItemID> = [renderItemId(forWorkspaceId: workspaceId)]
        if let groupId = workspaceById[workspaceId]?.groupId {
            ids.insert(.group(groupId))
        }
        publishRows(ids)
    }

    private func detailSnapshot(
        for workspace: Workspace
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let expectedKey = SidebarWorkspaceSnapshotFactory.presentationKey(
            settings: settings,
            showsAgentActivity: showsAgentActivity
        )
        if let cached = detailSnapshotByWorkspaceId[workspace.id],
           cached.presentationKey == expectedKey {
            return cached
        }
        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: showsAgentActivity,
            includesChecklistItems: false
        ).makeSnapshot()
        detailSnapshotByWorkspaceId[workspace.id] = snapshot
        return snapshot
    }

    private func refreshSettings() {
        let next = SidebarTabItemSettingsSnapshot(sidebarFontSize: sidebarFontSize)
        guard next != settings else { return }
        settings = next
        detailSnapshotByWorkspaceId.removeAll(keepingCapacity: true)
        var ids = Set(visibleWorkspaceIds.map(SidebarWorkspaceRenderItemID.workspace))
        ids.formUnion(groups.map { SidebarWorkspaceRenderItemID.group($0.id) })
        publishRows(ids)
    }

    private func changedSelectionItemIds(
        from old: Set<UUID>,
        to new: Set<UUID>
    ) -> Set<SidebarWorkspaceRenderItemID> {
        Set(old.symmetricDifference(new).map { renderItemId(forWorkspaceId: $0) })
    }

    private func renderItemId(forWorkspaceId workspaceId: UUID) -> SidebarWorkspaceRenderItemID {
        if let groupId = workspaceById[workspaceId]?.groupId,
           groupById[groupId]?.anchorWorkspaceId == workspaceId {
            return .group(groupId)
        }
        return .workspace(workspaceId)
    }

    private func publishRows(
        _ ids: Set<SidebarWorkspaceRenderItemID>,
        selectionChanged: Bool = false
    ) {
        guard !ids.isEmpty else { return }
        onChange?(.rows(ids, selectionChanged: selectionChanged))
    }
}
