import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxUpdater
import CmuxWorkspaces
import Observation

@MainActor
private final class SidebarNativeRootView: NSView {
    weak var owner: SidebarNativeViewController?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.hostWindowDidChange(window)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.effectiveAppearanceDidChange()
    }
}

/// Native owner for the default workspace sidebar. The controller keeps the
/// table identity stable, projects immutable row models, and routes actions
/// through the same AppKit row command surface used by the transitional host.
@MainActor
final class SidebarNativeViewController: NSViewController {
    private let updateViewModel: UpdateStateModel
    private let tabManager: TabManager
    private let sidebarSelectionState: SidebarSelectionState
    private let cmuxConfigStore: CmuxConfigStore
    private let sidebarUnread: SidebarUnreadModel
    private let onSendFeedback: () -> Void
    private let titlebarControlsLayoutModel: TitlebarControlsLayoutModel
    private let onToggleSidebar: () -> Void
    private let onNewTab: () -> Void

    private let tableController = SidebarWorkspaceTableController()
    private let settingsStore = SidebarTabItemSettingsStore(
        initialSidebarFontSize: GhosttyConfig.load().sidebarFontSize
    )
    private let modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    private let refreshScheduler = MainActorDeferredActionScheduler()
    private let dragAutoScrollController = SidebarDragAutoScrollController()
    private let dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    private let dragState: SidebarDragState
    private let titlebarDragHandle = WindowDragHandleNSView(doubleClickBehavior: .standardAction)
    private lazy var titlebarControlsOverlay = MinimalModeSidebarTitlebarControlsOverlayView(
        unreadModel: sidebarUnread,
        layoutModel: titlebarControlsLayoutModel,
        leadingInset: MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(),
        topInset: MinimalModeSidebarTitlebarControlsMetrics.topInset,
        onToggleSidebar: onToggleSidebar,
        onToggleNotifications: { anchorView in
            AppDelegate.shared?.toggleNotificationsPopover(
                animated: true,
                anchorView: anchorView
            )
        },
        onNewTab: onNewTab,
        onFocusHistoryBack: { [weak tabManager] in
            if tabManager?.navigateBack() != true { NSSound.beep() }
        },
        onFocusHistoryForward: { [weak tabManager] in
            if tabManager?.navigateForward() != true { NSSound.beep() }
        }
    )
    private lazy var footerController = SidebarFooterNativeViewController(
        updateViewModel: updateViewModel,
        tabManager: tabManager,
        modifierKeyMonitor: modifierKeyMonitor,
        onSendFeedback: onSendFeedback
    )

    private var selectedWorkspaceIds: Set<UUID> = []
    private var lastSelectionIndex: Int?
    private var expandedChecklistWorkspaceIds: Set<UUID> = []
    private var expandedMetadataWorkspaceIds: Set<UUID> = []
    private var expandedMarkdownWorkspaceIds: Set<UUID> = []
    private var checklistAddFieldActivationTokens: [UUID: Int] = [:]
    private var editingChecklistItemIds: [UUID: UUID] = [:]
    private var checklistPopoverWorkspaceId: UUID?
    private var observationGeneration: UInt64 = 0
    private var notificationTasks: [Task<Void, Never>] = []
    private var modelCancellables: Set<AnyCancellable> = []
    private var isPresentationActive = true
    private var lastObservedDraggedWorkspaceId: UUID?
    private var isBonsplitWorkspaceDropTargetCollectionActive = false

    init(
        updateViewModel: UpdateStateModel,
        tabManager: TabManager,
        sidebarSelectionState: SidebarSelectionState,
        cmuxConfigStore: CmuxConfigStore,
        sidebarUnread: SidebarUnreadModel,
        titlebarControlsLayoutModel: TitlebarControlsLayoutModel,
        onSendFeedback: @escaping () -> Void,
        onToggleSidebar: @escaping () -> Void,
        onNewTab: @escaping () -> Void
    ) {
        self.updateViewModel = updateViewModel
        self.tabManager = tabManager
        self.sidebarSelectionState = sidebarSelectionState
        self.cmuxConfigStore = cmuxConfigStore
        self.sidebarUnread = sidebarUnread
        self.titlebarControlsLayoutModel = titlebarControlsLayoutModel
        self.onSendFeedback = onSendFeedback
        self.onToggleSidebar = onToggleSidebar
        self.onNewTab = onNewTab
        dragState = SidebarDragState(
            workspaceDragRegistry: AppDelegate.shared?.sidebarWorkspaceDragRegistry
                ?? SidebarWorkspaceDragRegistry()
        )
        selectedWorkspaceIds = tabManager.selectedTabId.map { [$0] } ?? []
        lastSelectionIndex = tabManager.selectedTabId.flatMap { selectedId in
            tabManager.tabs.firstIndex { $0.id == selectedId }
        }
        super.init(nibName: nil, bundle: nil)
        tabManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &modelCancellables)
        sidebarSelectionState.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &modelCancellables)
        cmuxConfigStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            .store(in: &modelCancellables)
        observeInputs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            observationGeneration &+= 1
            refreshScheduler.cancel()
            notificationTasks.forEach { $0.cancel() }
            modifierKeyMonitor.stop()
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dragState.clearDrag()
        }
    }

    override func loadView() {
        let root = SidebarNativeRootView()
        root.owner = self
        root.wantsLayer = true
        root.setAccessibilityIdentifier("Sidebar")

        let tableContainer = tableController.makeContainerView()
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        footerController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(footerController)
        root.addSubview(tableContainer)
        root.addSubview(footerController.view)

        titlebarDragHandle.translatesAutoresizingMaskIntoConstraints = false
        titlebarControlsOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titlebarDragHandle)
        root.addSubview(titlebarControlsOverlay)

        let border = WindowChromeBorder(
            orientation: .vertical,
            ignoresSafeArea: true,
            refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
            backgroundColorProvider: { GhosttyBackgroundTheme.currentColor() }
        )
        border.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(border)

        NSLayoutConstraint.activate([
            tableContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tableContainer.topAnchor.constraint(equalTo: root.topAnchor),
            tableContainer.bottomAnchor.constraint(equalTo: footerController.view.topAnchor),
            footerController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titlebarDragHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarDragHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebarDragHandle.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarDragHandle.heightAnchor.constraint(equalToConstant: MinimalModeChromeMetrics.titlebarHeight),
            titlebarControlsOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarControlsOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            border.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            border.topAnchor.constraint(equalTo: root.topAnchor),
            border.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tableController.setUnreadSource(sidebarUnread)
        view = root
        activateSidebarInteractions()
        refresh()
    }

    func setPresentationActive(_ active: Bool) {
        guard isPresentationActive != active else { return }
        isPresentationActive = active
        tableController.setPresentationActive(active, workspaceIds: tabManager.tabs.map(\.id))
        if active {
            activateSidebarInteractions()
            scheduleRefresh()
        } else {
            deactivateSidebarInteractions()
        }
    }

    func teardown() {
        refreshScheduler.cancel()
        observationGeneration &+= 1
        notificationTasks.forEach { $0.cancel() }
        notificationTasks.removeAll(keepingCapacity: false)
        deactivateSidebarInteractions()
        if isViewLoaded {
            footerController.teardown()
        }
        if isViewLoaded, let container = findTableContainer(in: view) {
            tableController.dismantleContainerView(container)
        }
    }

    private func activateSidebarInteractions() {
        if showModifierHoldHints {
            modifierKeyMonitor.setHostWindow(viewIfLoaded?.window)
            modifierKeyMonitor.start()
        } else {
            modifierKeyMonitor.stop()
        }
        dragState.clearDrag()
        lastObservedDraggedWorkspaceId = nil
        isBonsplitWorkspaceDropTargetCollectionActive = false
        dragState.isSimulated = false
#if DEBUG
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            AppDelegate.shared?.sidebarDragStateRegistry.register(windowId: windowId, dragState: dragState)
        }
#endif
        SidebarDragLifecycleNotification().postStateDidChange(
            tabId: nil,
            reason: "sidebar_appear"
        )
    }

    private func deactivateSidebarInteractions() {
        modifierKeyMonitor.stop()
        modifierKeyMonitor.setHostWindow(nil)
        dragAutoScrollController.stop()
        dragFailsafeMonitor.stop()
        dragState.clearDrag()
        lastObservedDraggedWorkspaceId = nil
        isBonsplitWorkspaceDropTargetCollectionActive = false
        dragState.isSimulated = false
#if DEBUG
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            AppDelegate.shared?.sidebarDragStateRegistry.unregister(windowId: windowId)
        }
#endif
        SidebarDragLifecycleNotification().postStateDidChange(
            tabId: nil,
            reason: "sidebar_disappear"
        )
    }

    private func handleObservedDragStateChange() {
        let draggedWorkspaceId = dragState.draggedTabId
        guard draggedWorkspaceId != lastObservedDraggedWorkspaceId else { return }
        lastObservedDraggedWorkspaceId = draggedWorkspaceId
        SidebarDragLifecycleNotification().postStateDidChange(
            tabId: draggedWorkspaceId,
            reason: "drag_state_change"
        )
#if DEBUG
        cmuxDebugLog(
            "sidebar.dragState.sidebar tab=\(draggedWorkspaceId?.uuidString.prefix(5) ?? "nil")"
        )
#endif
        if draggedWorkspaceId != nil {
            if !dragState.isSimulated {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification().postClearRequest(reason: $0)
                }
            }
        } else {
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dragState.clearDropIndicator()
        }
    }

    fileprivate func hostWindowDidChange(_ window: NSWindow?) {
        modifierKeyMonitor.setHostWindow(showModifierHoldHints ? window : nil)
        updateTitlebarControlsOverlay(window: window)
        scheduleRefresh()
    }

    fileprivate func effectiveAppearanceDidChange() {
        scheduleRefresh()
    }

    private func updateTitlebarControlsOverlay(window: NSWindow?) {
        titlebarControlsOverlay.update(
            leadingInset: MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(),
            topInset: window.map { minimalModeSidebarTitlebarControlsTopInset(in: $0) }
                ?? MinimalModeSidebarTitlebarControlsMetrics.topInset,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: { anchorView in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: anchorView
                )
            },
            onNewTab: onNewTab,
            onFocusHistoryBack: { [weak tabManager] in
                if tabManager?.navigateBack() != true { NSSound.beep() }
            },
            onFocusHistoryForward: { [weak tabManager] in
                if tabManager?.navigateForward() != true { NSSound.beep() }
            }
        )
    }

    private func observeInputs() {
        observeTrackedInputs()
        notificationTasks = [
            Task { @MainActor [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: SidebarMultiSelectionShouldCollapseEvent.notificationName
                ) {
                    guard !Task.isCancelled, let self else { return }
                    guard let model = notification.object as? SidebarMultiSelectionModel,
                          model === tabManager.sidebarMultiSelection,
                          let event = SidebarMultiSelectionShouldCollapseEvent(notification) else {
                        continue
                    }
                    collapseSelection(to: event.focusedWorkspaceId)
                }
            },
            Task { @MainActor [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: SidebarMultiSelectionDidHideEvent.notificationName
                ) {
                    guard !Task.isCancelled, let self else { return }
                    guard let model = notification.object as? SidebarMultiSelectionModel,
                          model === tabManager.sidebarMultiSelection,
                          let event = SidebarMultiSelectionDidHideEvent(notification) else {
                        continue
                    }
                    selectedWorkspaceIds.subtract(event.hiddenWorkspaceIds)
                    if let movedFocus = event.focusedWorkspaceId {
                        selectedWorkspaceIds.insert(movedFocus)
                        lastSelectionIndex = tabManager.tabs.firstIndex { $0.id == movedFocus }
                    }
                    scheduleRefresh()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .ghosttyConfigDidReload
                ) {
                    guard !Task.isCancelled, let self else { return }
                    self.scheduleRefresh()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .workspaceCurrentDirectoryDidChange
                ) {
                    guard !Task.isCancelled, let self else { return }
                    scheduleRefresh()
                }
            },
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UserDefaults.didChangeNotification
                ) {
                    guard !Task.isCancelled, let self else { return }
                    self.modifierKeyMonitor.setHostWindow(
                        self.showModifierHoldHints ? self.viewIfLoaded?.window : nil
                    )
                    self.updateTitlebarControlsOverlay(window: self.viewIfLoaded?.window)
                    self.scheduleRefresh()
                }
            },
            Task { @MainActor [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: SidebarDragLifecycleNotification.requestClear
                ) {
                    guard !Task.isCancelled, let self else { return }
                    guard dragState.draggedTabId != nil || dragState.dropIndicator != nil else { continue }
#if DEBUG
                    cmuxDebugLog(
                        "sidebar.dragClear tab=\(dragState.draggedTabId?.uuidString.prefix(5) ?? "nil") " +
                        "reason=\(SidebarDragLifecycleNotification().reason(from: notification))"
                    )
#endif
                    dragState.clearDrag()
                    handleObservedDragStateChange()
                    scheduleRefresh()
                }
            },
            Task { @MainActor [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: .workspaceChecklistAddItemRequested
                ) {
                    guard !Task.isCancelled, let self else { return }
                    guard let workspaceId = notification.userInfo?[WorkspaceTodoActions.workspaceIdUserInfoKey] as? UUID,
                          tabManager.tabs.contains(where: { $0.id == workspaceId }) else {
                        continue
                    }
                    if WorkspaceTodoFeature.checklistStyle == .popover {
                        checklistPopoverWorkspaceId = workspaceId
                    } else {
                        expandedChecklistWorkspaceIds.insert(workspaceId)
                    }
                    checklistAddFieldActivationTokens[workspaceId, default: 0] += 1
                    scheduleRefresh()
                }
            },
        ]
    }

    private func observeTrackedInputs() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = settingsStore.snapshot
            _ = modifierKeyMonitor.isModifierPressed
            _ = KeyboardShortcutSettingsObserver.shared.revision
            _ = tabManager.tabs.map(\.id)
            _ = tabManager.selectedTabId
            _ = tabManager.workspaceGroups
            _ = sidebarSelectionState.selection
            _ = dragState.draggedTabId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, observationGeneration == generation else { return }
                handleObservedDragStateChange()
                scheduleRefresh()
                observeTrackedInputs()
            }
        }
    }

    private func scheduleRefresh() {
        guard isPresentationActive else { return }
        refreshScheduler.schedule(zeroDelayPolicy: .yieldOnce) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard isViewLoaded, isPresentationActive else { return }
        synchronizeSelection()
        let workspaces = tabManager.tabs
        let settings = settingsStore.snapshot
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark
                : .light,
            globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
        )
        let groupMenuSnapshot = WorkspaceGroupMenuSnapshot(
            items: tabManager.workspaceGroups.map { .init(id: $0.id, name: $0.name) }
        )
        let groupsById = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0) })
        let memberIdsByGroupId = SidebarWorkspaceRenderItem.memberWorkspaceIdsByGroupId(tabs: workspaces)
        let renderItems = SidebarWorkspaceRenderItem.renderItems(
            tabs: workspaces,
            groupsById: groupsById
        )
        let numberedIndexById = SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(
            from: renderItems
        )
        let workspacesById = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let rows = renderItems.compactMap { item -> SidebarWorkspaceTableRowConfiguration? in
            switch item {
            case .groupHeader(let groupId, _):
                guard let group = groupsById[groupId] else { return nil }
                return groupRowConfiguration(
                    group,
                    memberWorkspaceIds: memberIdsByGroupId[groupId] ?? [],
                    workspacesById: workspacesById,
                    settings: settings,
                    environment: environment,
                    isFirstRow: renderItems.first?.id == item.id
                )
            case .workspace(let workspaceId):
                guard let workspace = workspacesById[workspaceId],
                      let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
                    return nil
                }
                return workspaceRowConfiguration(
                    workspace,
                    index: index,
                    shortcutIndex: numberedIndexById[workspaceId],
                    shortcutWorkspaceCount: numberedIndexById.count,
                    workspaces: workspaces,
                    settings: settings,
                    environment: environment,
                    groupMenuSnapshot: groupMenuSnapshot
                )
            }
        }
        let selectedScrollTargetWorkspaceId = tabManager.selectedTabId.map { selectedId in
            let group = workspacesById[selectedId]?.groupId.flatMap { groupsById[$0] }
            return SidebarSelectedWorkspaceScrollPolicy.scrollTargetWorkspaceId(
                selectedWorkspaceId: selectedId,
                group: group
            )
        }
        tableController.apply(
            rows: rows,
            actions: tableActions(),
            workspaceIds: workspaces.map(\.id),
            selectedWorkspaceId: tabManager.selectedTabId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
        footerController.update(
            tabManager: tabManager,
            modifierKeyMonitor: modifierKeyMonitor,
            onSendFeedback: onSendFeedback
        )
    }

    private var showModifierHoldHints: Bool {
        let setting = SettingCatalog().shortcuts.showModifierHoldHints
        return UserDefaults.standard.object(forKey: setting.userDefaultsKey) as? Bool
            ?? setting.defaultValue
    }

    private func synchronizeSelection() {
        let liveIds = Set(tabManager.tabs.map(\.id))
        selectedWorkspaceIds.formIntersection(liveIds)
        if selectedWorkspaceIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedWorkspaceIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private func collapseSelection(to focusedWorkspaceId: UUID) {
        guard tabManager.tabs.contains(where: { $0.id == focusedWorkspaceId }) else {
            selectedWorkspaceIds = []
            lastSelectionIndex = nil
            scheduleRefresh()
            return
        }
        selectedWorkspaceIds = [focusedWorkspaceId]
        lastSelectionIndex = tabManager.tabs.firstIndex { $0.id == focusedWorkspaceId }
        scheduleRefresh()
    }

    private func workspaceRowConfiguration(
        _ workspace: Workspace,
        index: Int,
        shortcutIndex: Int?,
        shortcutWorkspaceCount: Int,
        workspaces: [Workspace],
        settings: SidebarTabItemSettingsSnapshot,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        groupMenuSnapshot: WorkspaceGroupMenuSnapshot
    ) -> SidebarWorkspaceTableRowConfiguration {
        let contextWorkspaceIds = selectedWorkspaceIds.contains(workspace.id)
            ? workspaces.filter { selectedWorkspaceIds.contains($0.id) }.map(\.id)
            : [workspace.id]
        let contextWorkspaces = workspaces.filter { contextWorkspaceIds.contains($0.id) }
        let remoteTargets = contextWorkspaces.filter {
            $0.isRemoteWorkspace && !$0.isManagedCloudVMWorkspace
        }
        let pinContext = WorkspaceActionDispatcher.PinResolutionContext(
            workspacesById: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            liveWorkspaceIds: Set(workspaces.map(\.id))
        )
        let pinState = WorkspaceActionDispatcher.pinState(
            in: pinContext,
            target: WorkspaceActionDispatcher.Target(
                workspaceIds: contextWorkspaceIds,
                anchorWorkspaceId: workspace.id
            )
        )
        let snapshot = makeWorkspaceSnapshot(workspace, settings: settings)
        let model = makeWorkspaceRowModel(
            workspace,
            index: index,
            workspaceCount: workspaces.count,
            shortcutIndex: shortcutIndex,
            shortcutWorkspaceCount: shortcutWorkspaceCount,
            settings: settings,
            environment: environment,
            snapshot: snapshot,
            unreadSummary: SidebarWorkspaceUnreadSummary(unreadCount: 0, latestNotificationText: nil)
        )
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: tabManager,
            notificationStore: TerminalNotificationStore.shared,
            index: index,
            contextMenuWorkspaceIds: contextWorkspaceIds,
            remoteContextMenuWorkspaceIds: remoteTargets.map(\.id),
            allRemoteContextMenuTargetsConnecting: !remoteTargets.isEmpty && remoteTargets.allSatisfy {
                $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting
            },
            allRemoteContextMenuTargetsDisconnected: !remoteTargets.isEmpty && remoteTargets.allSatisfy {
                $0.remoteConnectionState == .disconnected
            },
            contextMenuPinState: pinState,
            workspaceGroupMenuSnapshot: groupMenuSnapshot,
            refreshSnapshot: { [weak self] in self?.scheduleRefresh() },
            readSelectedTabIds: { [weak self] in self?.selectedWorkspaceIds ?? [] },
            writeSelectedTabIds: { [weak self] in
                self?.selectedWorkspaceIds = $0
                self?.scheduleRefresh()
            },
            readLastSelectionIndex: { [weak self] in self?.lastSelectionIndex },
            writeLastSelectionIndex: { [weak self] in self?.lastSelectionIndex = $0 },
            setSelectionToTabs: { [weak self] in self?.sidebarSelectionState.selection = .tabs },
            currentWindowMoveTargets: { [weak tabManager] in
                guard let tabManager, let app = AppDelegate.shared else { return [] }
                return app.windowMoveTargets(referenceWindowId: app.windowId(for: tabManager)).map {
                    SidebarWorkspaceWindowMoveTarget(
                        windowId: $0.windowId,
                        label: $0.label,
                        isCurrentWindow: $0.isCurrentWindow
                    )
                }
            },
            snapshotProvider: { [weak workspace] in
                guard let workspace else { return nil }
                return SidebarWorkspaceSnapshotFactory(
                    workspace: workspace,
                    settings: settings,
                    showsAgentActivity: Self.showsAgentActivity(settings)
                ).makeSnapshot()
            }
        )
        let actions = workspaceRowActions(workspace: workspace, commands: commands, settings: settings)
        return SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: actions,
            groupId: workspace.groupId,
            isPinned: workspace.isPinned,
            environment: environment,
            workspace: workspace,
            rebuild: { [weak self, weak workspace] in
                guard let self, let workspace else { return model }
                let nextSnapshot = self.makeWorkspaceSnapshot(workspace, settings: settings)
                return self.makeWorkspaceRowModel(
                    workspace,
                    index: self.tabManager.tabs.firstIndex { $0.id == workspace.id } ?? index,
                    workspaceCount: self.tabManager.tabs.count,
                    shortcutIndex: shortcutIndex,
                    shortcutWorkspaceCount: shortcutWorkspaceCount,
                    settings: settings,
                    environment: environment,
                    snapshot: nextSnapshot,
                    unreadSummary: self.sidebarUnread.snapshot.summary(forWorkspaceId: workspace.id)
                )
            },
            unreadRebuild: { [model, workspaceId = workspace.id] unreadSnapshot in
                let summary = unreadSnapshot.summary(forWorkspaceId: workspaceId)
                var fresh = model
                fresh.unreadCount = summary.unreadCount
                fresh.latestNotificationText = settings.showsNotificationMessage
                    ? summary.latestNotificationText
                    : nil
                return fresh
            }
        )
    }

    private func makeWorkspaceSnapshot(
        _ workspace: Workspace,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: Self.showsAgentActivity(settings)
        ).makeSnapshot()
    }

    private func groupRowConfiguration(
        _ group: WorkspaceGroup,
        memberWorkspaceIds: [UUID],
        workspacesById: [UUID: Workspace],
        settings: SidebarTabItemSettingsSnapshot,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        isFirstRow: Bool
    ) -> SidebarWorkspaceTableRowConfiguration {
        let anchorWorkspace = workspacesById[group.anchorWorkspaceId]
        let resolvedConfig = cmuxConfigStore.resolveWorkspaceGroupConfig(
            forCwd: anchorWorkspace?.currentDirectory
        )
        let effectiveColor = group.customColor ?? resolvedConfig?.color
        let effectiveIcon = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(
            explicit: group.iconSymbol,
            configured: resolvedConfig?.iconSymbol
        )
        let unreadSnapshot = sidebarUnread.snapshot
        let notificationStore = TerminalNotificationStore.shared
        let nonAnchorMemberIds = memberWorkspaceIds.filter { $0 != group.anchorWorkspaceId }
        let model = SidebarGroupHeaderRowModel(
            groupId: group.id,
            anchorWorkspaceId: group.anchorWorkspaceId,
            name: group.name,
            iconSymbol: effectiveIcon,
            tintHex: effectiveColor,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            isAnchorActive: tabManager.selectedTabId == group.anchorWorkspaceId,
            isMultiSelected: selectedWorkspaceIds.contains(group.anchorWorkspaceId)
                && selectedWorkspaceIds.count > 1,
            multiSelectionBackgroundStyle: sidebarWorkspaceRowBackgroundStyle(
                activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
                isActive: false,
                isMultiSelected: true,
                customColorHex: effectiveColor,
                colorScheme: environment.colorScheme,
                sidebarSelectionColorHex: settings.selectionColorHex
            ),
            memberCount: memberWorkspaceIds.count,
            anchorUnreadCount: group.isCollapsed
                ? memberWorkspaceIds.reduce(0) {
                    $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1)
                }
                : unreadSnapshot.unreadCount(forWorkspaceId: group.anchorWorkspaceId),
            canMarkRead: unreadSnapshot.canMarkWorkspaceRead(
                forWorkspaceIds: [group.anchorWorkspaceId]
            ),
            canMarkUnread: unreadSnapshot.canMarkWorkspaceUnread(
                forWorkspaceIds: [group.anchorWorkspaceId]
            ),
            hasLatestNotifications: unreadSnapshot
                .summary(forWorkspaceId: group.anchorWorkspaceId)
                .hasLatestNotification,
            canMarkAllRead: unreadSnapshot.canMarkWorkspaceRead(
                forWorkspaceIds: nonAnchorMemberIds
            ),
            canMarkAllUnread: unreadSnapshot.canMarkWorkspaceUnread(
                forWorkspaceIds: nonAnchorMemberIds
            ),
            shortcutHintText: nil,
            shortcutHintXOffset: settings.sidebarShortcutHintXOffset,
            shortcutHintYOffset: settings.sidebarShortcutHintYOffset,
            fontScale: settings.sidebarFontScale,
            globalFontMagnificationPercent: environment.globalFontMagnificationPercent,
            cwdContextMenuItems: resolvedConfig?.contextMenuItems ?? [],
            rowSpacing: 2,
            isFirstRow: isFirstRow,
            isBeingDragged: dragState.draggedTabId == group.anchorWorkspaceId,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false
        )
        let actions = SidebarGroupHeaderRowActions(
            onToggleCollapsed: { [weak self] in
                self?.tabManager.toggleWorkspaceGroupCollapsed(groupId: group.id)
                self?.scheduleRefresh()
            },
            onFocusAnchor: { [weak self] modifiers in
                guard let self,
                      let anchor = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId }) else {
                    return
                }
                if modifiers.contains(.command) || modifiers.contains(.shift) {
                    let anchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
                    selectedWorkspaceIds = SidebarSelectionKindPolicy().anchorCmdClickSelection(
                        current: selectedWorkspaceIds,
                        clickedAnchorId: group.anchorWorkspaceId,
                        anchorIds: anchorIds
                    )
                } else {
                    selectedWorkspaceIds = [group.anchorWorkspaceId]
                }
                tabManager.selectWorkspace(anchor)
                lastSelectionIndex = tabManager.tabs.firstIndex { $0.id == group.anchorWorkspaceId }
                sidebarSelectionState.selection = .tabs
                scheduleRefresh()
            },
            onTapPlus: { [weak self] in
                guard let self else { return }
                let placement = resolvedConfig?.newWorkspacePlacement
                    ?? UserDefaultsSettingsClient(defaults: .standard).value(
                        for: SettingCatalog().workspaceGroups.newWorkspacePlacement
                    )
                _ = tabManager.createWorkspaceInGroup(groupId: group.id, placement: placement)
                scheduleRefresh()
            },
            onRunResolvedItem: { [weak self] item in
                guard let self else { return }
                SidebarWorkspaceGroupContextMenuRunner.run(
                    item: item,
                    tabManager: tabManager,
                    groupId: group.id
                )
            },
            onRename: { [weak self] in
                guard let self else { return }
                presentSidebarWorkspaceGroupRenamePrompt(
                    tabManager: tabManager,
                    groupId: group.id,
                    currentName: group.name
                )
            },
            onTogglePinned: { [weak self] in
                self?.tabManager.toggleWorkspaceGroupPinned(groupId: group.id)
            },
            onMarkRead: { [weak notificationStore] in
                notificationStore?.markRead(forTabId: group.anchorWorkspaceId)
            },
            onMarkUnread: { [weak notificationStore] in
                notificationStore?.markUnread(forTabId: group.anchorWorkspaceId)
            },
            onClearLatestNotifications: { [weak notificationStore] in
                notificationStore?.clearLatestNotification(forTabId: group.anchorWorkspaceId)
            },
            onMarkAllRead: { [weak tabManager, weak notificationStore] in
                guard let tabManager, let notificationStore else { return }
                let ids = tabManager.tabs.compactMap {
                    $0.groupId == group.id && $0.id != group.anchorWorkspaceId ? $0.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                    notificationStore.markRead(forTabId: id)
                }
            },
            onMarkAllUnread: { [weak tabManager, weak notificationStore] in
                guard let tabManager, let notificationStore else { return }
                let ids = tabManager.tabs.compactMap {
                    $0.groupId == group.id && $0.id != group.anchorWorkspaceId ? $0.id : nil
                }
                for id in ids where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                    notificationStore.markUnread(forTabId: id)
                }
            },
            onUngroup: { [weak self] in
                self?.tabManager.ungroupWorkspaceGroup(groupId: group.id)
            },
            onDelete: { [weak self] in
                guard let self,
                      let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                        groupId: group.id,
                        fallbackGroupName: group.name,
                        fallbackAnchorWorkspaceId: group.anchorWorkspaceId
                      ) else {
                    return
                }
                if confirmation.containedWorkspaceCount > 0,
                   !confirmDeleteWorkspaceGroup(
                    groupName: confirmation.groupName,
                    memberCount: confirmation.containedWorkspaceCount
                   ) {
                    return
                }
                tabManager.workspaceGrouping.deleteWorkspaceGroup(confirmed: confirmation)
            },
            onEditConfig: { SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor() },
            onOpenDocs: { SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs() }
        )
        return SidebarWorkspaceTableRowConfiguration(
            groupHeaderModel: model,
            actions: actions,
            environment: environment,
            unreadDependencyWorkspaceIds: Set(memberWorkspaceIds).union([group.anchorWorkspaceId]),
            unreadRebuild: { [model] snapshot in
                var fresh = model
                fresh.anchorUnreadCount = group.isCollapsed
                    ? memberWorkspaceIds.reduce(0) {
                        $0 + snapshot.unreadCount(forWorkspaceId: $1)
                    }
                    : snapshot.unreadCount(forWorkspaceId: group.anchorWorkspaceId)
                fresh.canMarkRead = snapshot.canMarkWorkspaceRead(
                    forWorkspaceIds: [group.anchorWorkspaceId]
                )
                fresh.canMarkUnread = snapshot.canMarkWorkspaceUnread(
                    forWorkspaceIds: [group.anchorWorkspaceId]
                )
                fresh.hasLatestNotifications = snapshot
                    .summary(forWorkspaceId: group.anchorWorkspaceId)
                    .hasLatestNotification
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

    private static func showsAgentActivity(_ settings: SidebarTabItemSettingsSnapshot) -> Bool {
        settings.details.showAgentActivity
            && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled
    }

    private func makeWorkspaceRowModel(
        _ workspace: Workspace,
        index: Int,
        workspaceCount: Int,
        shortcutIndex: Int?,
        shortcutWorkspaceCount: Int,
        settings: SidebarTabItemSettingsSnapshot,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        unreadSummary: SidebarWorkspaceUnreadSummary
    ) -> SidebarWorkspaceRowModel {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
        let showsHints = (showModifierHoldHints && modifierKeyMonitor.isModifierPressed)
            || settings.alwaysShowShortcutHints
        let shortcutDigit = WorkspaceShortcutMapper.digitForWorkspace(
            at: shortcutIndex ?? -1,
            workspaceCount: shortcutWorkspaceCount
        )
        let shortcutHintText = shortcutDigit.flatMap { digit in
            showsHints ? "\(shortcut.numberedDigitHintPrefix)\(digit)" : nil
        }
        return SidebarWorkspaceRowModel(
            workspaceId: workspace.id,
            index: index,
            snapshot: snapshot,
            settings: settings,
            isActive: tabManager.selectedTabId == workspace.id,
            isMultiSelected: selectedWorkspaceIds.contains(workspace.id),
            canCloseWorkspace: workspaceCount > 1,
            accessibilityWorkspaceCount: workspaceCount,
            unreadCount: unreadSummary.unreadCount,
            latestNotificationText: settings.showsNotificationMessage
                ? unreadSummary.latestNotificationText
                : nil,
            showsAgentActivity: Self.showsAgentActivity(settings),
            rowSpacing: 2,
            isBeingDragged: dragState.draggedTabId == workspace.id,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: workspace.groupId != nil,
            isFirstRow: index == 0,
            shortcutHintText: shortcutHintText,
            showsShortcutHints: showsHints,
            colorSchemeIsDark: environment.colorScheme == .dark,
            globalFontMagnificationPercent: environment.globalFontMagnificationPercent,
            isChecklistExpanded: expandedChecklistWorkspaceIds.contains(workspace.id),
            checklistAddFieldActivationToken: checklistAddFieldActivationTokens[workspace.id] ?? 0,
            isChecklistPopoverPresented: checklistPopoverWorkspaceId == workspace.id,
            editingChecklistItemId: editingChecklistItemIds[workspace.id],
            todoControlsEnabled: WorkspaceTodoFeature.isEnabled,
            isMetadataExpanded: expandedMetadataWorkspaceIds.contains(workspace.id),
            isMarkdownExpanded: expandedMarkdownWorkspaceIds.contains(workspace.id)
        )
    }

    private func workspaceRowActions(
        workspace: Workspace,
        commands: SidebarWorkspaceRowCommands,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarAppKitRowActions {
        let openInBrowser: @MainActor (URL, Bool) -> Void = { [weak tabManager, workspaceId = workspace.id] url, preferBrowser in
            if preferBrowser,
               let tabManager,
               tabManager.openBrowser(
                   inWorkspace: workspaceId,
                   url: url,
                   preferSplitRight: true,
                   insertAtEnd: true
               ) != nil {
                return
            }
            NSWorkspace.shared.open(url)
        }
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenStatusURL: { NSWorkspace.shared.open($0) },
            onOpenPullRequest: { openInBrowser($0, settings.openPullRequestLinksInCmuxBrowser) },
            onOpenPort: { port in
                guard let url = URL(string: "http://localhost:\(port)") else { return }
                openInBrowser(url, settings.openPortLinksInCmuxBrowser)
            },
            onToggleChecklistExpansion: { [weak self] in
                self?.toggle(workspace.id, at: \.expandedChecklistWorkspaceIds)
            },
            onToggleMetadataExpansion: { [weak self] in
                self?.toggle(workspace.id, at: \.expandedMetadataWorkspaceIds)
            },
            onToggleMarkdownExpansion: { [weak self] in
                self?.toggle(workspace.id, at: \.expandedMarkdownWorkspaceIds)
            },
            onConsumeChecklistAddFieldActivation: { [weak self] in
                self?.checklistAddFieldActivationTokens[workspace.id] = nil
                self?.scheduleRefresh()
            },
            checklistSetItemState: { WorkspaceTodoActions.setChecklistItemState(id: $0, state: $1, in: workspace) },
            checklistRemoveItem: { WorkspaceTodoActions.removeChecklistItem(id: $0, from: workspace) },
            checklistAddItem: { WorkspaceTodoActions.addChecklistItem(text: $0, to: workspace) },
            checklistEditItem: { WorkspaceTodoActions.editChecklistItem(id: $0, text: $1, in: workspace) },
            checklistMoveItem: { WorkspaceTodoActions.moveChecklistItem(id: $0, toIndex: $1, in: workspace) },
            checklistOpenPane: { WorkspaceTodoActions.openTodoPane(for: workspace) },
            checklistAddAttachments: { WorkspaceTodoActions.addImageAttachments(to: $0, in: workspace) },
            checklistRemoveAttachment: {
                WorkspaceTodoActions.removeImageAttachment(itemId: $0, attachmentId: $1, from: workspace)
            },
            checklistOpenAttachments: { itemId, selectedAttachmentId in
                guard let item = workspace.todoState.checklist.first(where: { $0.id == itemId }) else { return }
                WorkspaceTodoActions.openImageAttachments(
                    item.attachments,
                    selectedAttachmentId: selectedAttachmentId
                )
            },
            onChecklistPopoverPresentedChange: { [weak self] presented in
                guard let self else { return }
                if presented {
                    checklistPopoverWorkspaceId = workspace.id
                } else if checklistPopoverWorkspaceId == workspace.id {
                    checklistPopoverWorkspaceId = nil
                }
                scheduleRefresh()
            },
            onBeginChecklistItemEdit: { [weak self] itemId in
                self?.editingChecklistItemIds[workspace.id] = itemId
                self?.scheduleRefresh()
            },
            onEndChecklistItemEdit: { [weak self] itemId in
                guard let self, editingChecklistItemIds[workspace.id] == itemId else { return }
                editingChecklistItemIds[workspace.id] = nil
                scheduleRefresh()
            },
            applyTodoStatus: { WorkspaceTodoActions.applyStatusOverride($0, to: [workspace]) },
            hideTodoStatus: { WorkspaceTodoActions.hideStatus(for: [workspace]) },
            commitRename: { [weak tabManager] in
                tabManager?.setCustomTitle(tabId: workspace.id, title: $0)
            }
        )
    }

    private func toggle(
        _ workspaceId: UUID,
        at keyPath: ReferenceWritableKeyPath<SidebarNativeViewController, Set<UUID>>
    ) {
        var set = self[keyPath: keyPath]
        if set.contains(workspaceId) {
            set.remove(workspaceId)
        } else {
            set.insert(workspaceId)
        }
        self[keyPath: keyPath] = set
        scheduleRefresh()
    }

    private func tableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { [weak self] scrollView in
                self?.dragAutoScrollController.attach(scrollView: scrollView)
            },
            closeWorkspace: { [weak tabManager] workspaceId in
                guard let workspace = tabManager?.tabs.first(where: { $0.id == workspaceId }) else { return }
                tabManager?.closeWorkspaceWithConfirmation(workspace)
            },
            createWorkspaceAtEnd: { [weak self] in
                guard let self else { return }
                if tabManager.selectedTab?.isRemoteTmuxMirror == true {
                    _ = AppDelegate.shared?.performNewWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.emptyArea.remoteTmux"
                    )
                } else {
                    tabManager.addWorkspace(placementOverride: .end)
                }
                sidebarSelectionState.selection = .tabs
                synchronizeSelection()
                scheduleRefresh()
            },
            createEmptyWorkspaceGroup: { [weak tabManager] in
                guard let tabManager, tabManager.selectedTab?.isRemoteTmuxMirror != true else { return }
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
            },
            beginWorkspaceDrag: { [weak self] workspaceId in
                guard let self else { return }
                dragState.beginDragging(tabId: workspaceId)
                handleObservedDragStateChange()
                scheduleRefresh()
            },
            movingWorkspaceCount: { [weak self] workspaceId in
                guard let self else { return 1 }
                return SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                    orderedWorkspaceIds: tabManager.tabs.map(\.id),
                    selectedIds: selectedWorkspaceIds,
                    draggedId: workspaceId,
                    anchorIds: Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
                ).count
            },
            endWorkspaceDrag: { [weak self] in
                guard let self else { return }
                dragState.clearDrag()
                handleObservedDragStateChange()
                scheduleRefresh()
            },
            isValidWorkspaceDrag: { [weak self] in
                self?.activateSidebarWorkspaceDragIfNeeded() ?? false
            },
            updateWorkspaceDrag: { [weak self] point, targets, pasteboardWorkspaceId in
                self?.updateWorkspaceReorderDropForTable(
                    point: point,
                    targets: targets,
                    pasteboardWorkspaceId: pasteboardWorkspaceId
                )
            },
            performWorkspaceDrop: { [weak self] point, targets, pasteboardWorkspaceId in
                self?.performWorkspaceReorderDrop(
                    point: point,
                    targets: targets,
                    pasteboardWorkspaceId: pasteboardWorkspaceId
                ) ?? false
            },
            commitWorkspaceDropPlan: { [weak self] plan in
                guard let self else { return false }
                defer {
                    dragState.clearDrag()
                    handleObservedDragStateChange()
                    scheduleRefresh()
                }
                return performWorkspaceReorderPlan(plan)
            },
            clearWorkspaceDropIndicator: { [weak self] in
                self?.dragState.clearDropIndicator()
                self?.dragAutoScrollController.stop()
            },
            currentDropIndicator: { [weak self] in self?.dragState.dropIndicator },
            currentDropIndicatorScope: { [weak self] in self?.dragState.dropIndicatorScope ?? .raw },
            canPerformBonsplitAction: { action, transfer in
                guard let app = AppDelegate.shared else { return false }
                switch action {
                case .existingWorkspace(let workspaceId):
                    if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                       source.workspaceId == workspaceId {
                        return true
                    }
                    return app.canMoveBonsplitTab(tabId: transfer.tab.id, toWorkspace: workspaceId)
                case .newWorkspace:
                    return app.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id)
                }
            },
            moveBonsplitToExistingWorkspace: { workspaceId, transfer in
                guard let app = AppDelegate.shared else { return false }
                if let source = app.locateBonsplitSurface(tabId: transfer.tab.id),
                   source.workspaceId == workspaceId {
                    return true
                }
                return app.moveBonsplitTab(
                    tabId: transfer.tab.id,
                    toWorkspace: workspaceId,
                    focus: true,
                    focusWindow: true
                )
            },
            moveBonsplitToNewWorkspace: { [weak tabManager] insertionIndex, transfer in
                guard let tabManager, let app = AppDelegate.shared else { return nil }
                return app.moveBonsplitTabToNewWorkspace(
                    tabId: transfer.tab.id,
                    destinationManager: tabManager,
                    focus: true,
                    focusWindow: true,
                    insertionIndexOverride: insertionIndex
                )?.destinationWorkspaceId
            },
            didMoveBonsplitToWorkspace: { [weak self] workspaceId in
                self?.selectedWorkspaceIds = [workspaceId]
                self?.lastSelectionIndex = self?.tabManager.tabs.firstIndex { $0.id == workspaceId }
                self?.scheduleRefresh()
            },
            updateDragAutoscroll: { [weak self] in
                self?.dragAutoScrollController.updateFromDragLocation()
            },
            setBonsplitDropTargetCollectionActive: { [weak self] active in
                self?.isBonsplitWorkspaceDropTargetCollectionActive = active
            },
            setBonsplitDropIndicator: { [weak self] indicator in
                self?.dragState.setDropIndicator(indicator)
            }
        )
    }

    private func activateSidebarWorkspaceDragIfNeeded(
        pasteboardWorkspaceId: UUID? = nil
    ) -> Bool {
        if dragState.draggedTabId != nil {
            return true
        }
        guard let dragId = dragState.currentWorkspaceDragId ?? pasteboardWorkspaceId else {
#if DEBUG
            cmuxDebugLog("sidebar.drag.activate rejected reason=noDragId")
#endif
            return false
        }
        if tabManager.tabs.contains(where: { $0.id == dragId }) {
            let isSourceGroupAnchor = tabManager.workspaceGroups.contains {
                $0.anchorWorkspaceId == dragId
            }
            guard !SidebarWorkspaceDragActivationPolicy().shouldRejectRecovery(
                isLocalWorkspace: true,
                isSourceGroupAnchor: isSourceGroupAnchor
            ) else {
                return false
            }
            dragState.beginDragging(tabId: dragId)
            handleObservedDragStateChange()
            return true
        }
        guard let sourceManager = AppDelegate.shared?.tabManagerFor(tabId: dragId) else {
            return false
        }
        let isSourceGroupAnchor = sourceManager.workspaceGroups.contains {
            $0.anchorWorkspaceId == dragId
        }
        guard !SidebarWorkspaceDragActivationPolicy().shouldRejectRecovery(
            isLocalWorkspace: false,
            isSourceGroupAnchor: isSourceGroupAnchor
        ) else {
            return false
        }
        dragState.foreignDraggedIsPinned = sourceManager.tabs.first { $0.id == dragId }?.isPinned ?? false
        dragState.draggedTabId = dragId
        handleObservedDragStateChange()
        return true
    }

    private func updateWorkspaceReorderDropForTable(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        pasteboardWorkspaceId: UUID?
    ) -> SidebarWorkspaceTableReorderDropUpdate? {
        guard activateSidebarWorkspaceDragIfNeeded(pasteboardWorkspaceId: pasteboardWorkspaceId),
              let draggedWorkspaceId = dragState.draggedTabId,
              let plan = workspaceReorderPlan(point: point, targets: targets) else {
            return nil
        }
        dragAutoScrollController.updateFromDragLocation()
        return SidebarWorkspaceTableReorderDropUpdate(
            indicator: plan.indicator,
            scope: plan.indicatorScope,
            draggedWorkspaceId: draggedWorkspaceId,
            indicatorRowIds: sidebarDropIndicatorRowIds(
                draggedWorkspaceId: draggedWorkspaceId,
                scope: plan.indicatorScope
            ),
            plan: plan
        )
    }

    private func performWorkspaceReorderDrop(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        pasteboardWorkspaceId: UUID?
    ) -> Bool {
        defer {
            dragState.clearDrag()
            handleObservedDragStateChange()
            dragAutoScrollController.stop()
            scheduleRefresh()
        }
        guard activateSidebarWorkspaceDragIfNeeded(pasteboardWorkspaceId: pasteboardWorkspaceId),
              let plan = workspaceReorderPlan(point: point, targets: targets) else {
            return false
        }
        return performWorkspaceReorderPlan(plan)
    }

    private func workspaceReorderPlan(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target]
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let draggedWorkspaceId = dragState.draggedTabId else { return nil }
        return SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedWorkspaceId,
                foreignDraggedIsPinned: dragState.foreignDraggedIsPinned,
                workspaces: tabManager.tabs.map {
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: $0.id,
                        isPinned: $0.isPinned,
                        groupId: $0.groupId
                    )
                },
                groups: tabManager.workspaceGroups.map {
                    SidebarWorkspaceReorderGroupSnapshot(
                        id: $0.id,
                        anchorWorkspaceId: $0.anchorWorkspaceId,
                        isPinned: $0.isPinned
                    )
                },
                targets: targets.map {
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: $0.workspaceId,
                        groupId: $0.groupId,
                        isGroupHeader: $0.isGroupHeader,
                        frame: $0.frame
                    )
                }
            )
        )
    }

    private func performWorkspaceReorderPlan(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        switch plan.action {
        case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId):
            let selectionBeforeReorder = selectedWorkspaceIds
            let anchorWorkspaceIdBeforeReorder = SidebarWorkspaceSelectionSyncPolicy().anchorWorkspaceId(
                existingAnchorIndex: lastSelectionIndex,
                liveWorkspaceIds: tabManager.tabs.map(\.id)
            )
            let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
                orderedWorkspaceIds: tabManager.tabs.map(\.id),
                selectedIds: selectedWorkspaceIds,
                draggedId: plan.draggedWorkspaceId,
                anchorIds: Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
            )
            let didReorder: Bool
            if movingIds.count > 1 {
                didReorder = tabManager.reorderSidebarWorkspaces(
                    tabIds: movingIds,
                    draggedTabId: plan.draggedWorkspaceId,
                    toIndex: targetIndex,
                    isDragOperation: true,
                    usesTopLevelRows: usesTopLevelRows,
                    explicitGroupId: explicitGroupId
                )
            } else {
                didReorder = tabManager.reorderSidebarWorkspace(
                    tabId: plan.draggedWorkspaceId,
                    toIndex: targetIndex,
                    isDragOperation: true,
                    usesTopLevelRows: usesTopLevelRows,
                    explicitGroupId: explicitGroupId
                )
            }
            syncSidebarSelectionAfterWorkspaceReorder(
                preserving: selectionBeforeReorder,
                preferredAnchorWorkspaceId: anchorWorkspaceIdBeforeReorder
            )
            return didReorder
        case .crossWindow(insertionIndex: _, proposedInsertionIndex: let proposedInsertionIndex):
            return performCrossWindowWorkspaceDrop(
                plan: plan,
                proposedInsertionIndex: proposedInsertionIndex
            )
        }
    }

    private func performCrossWindowWorkspaceDrop(
        plan: SidebarWorkspaceReorderDropPlan,
        proposedInsertionIndex: Int
    ) -> Bool {
        guard let app = AppDelegate.shared,
              let destinationWindowId = app.windowId(for: tabManager),
              let sourceManager = app.tabManagerFor(tabId: plan.draggedWorkspaceId),
              !sourceManager.workspaceGroups.contains(where: {
                  $0.anchorWorkspaceId == plan.draggedWorkspaceId
              }) else {
            return false
        }

        let movingIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: sourceManager.tabs.map(\.id),
            selectedIds: sourceManager.sidebarSelectedWorkspaceIds,
            draggedId: plan.draggedWorkspaceId,
            anchorIds: Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))
        )
        guard !movingIds.isEmpty else { return false }

        let pinStateById = Dictionary(uniqueKeysWithValues: movingIds.map { id in
            (id, sourceManager.tabs.first { $0.id == id }?.isPinned ?? false)
        })
        var movedIds: [UUID] = []
        for isPinnedTier in [false, true] {
            let tierIds = movingIds.filter { (pinStateById[$0] ?? false) == isPinnedTier }
            guard !tierIds.isEmpty else { continue }
            let topLevelIds = crossWindowTopLevelWorkspaceIds()
            let slot = clampedCrossWindowTopLevelSlot(
                proposedInsertionIndex,
                draggedIsPinned: isPinnedTier,
                topLevelIds: topLevelIds,
                pinnedTopLevelIds: crossWindowTopLevelPinnedWorkspaceIds()
            )
            let base = crossWindowRawInsertIndex(
                forTopLevelSlot: slot,
                topLevelIds: topLevelIds
            )
            var tierOffset = 0
            for workspaceId in tierIds {
                if app.moveWorkspaceToWindow(
                    workspaceId: workspaceId,
                    windowId: destinationWindowId,
                    atIndex: base + tierOffset,
                    focus: false
                ) {
                    movedIds.append(workspaceId)
                    tierOffset += 1
                }
            }
        }

        guard !movedIds.isEmpty else { return false }
        let focusId = movedIds.contains(plan.draggedWorkspaceId)
            ? plan.draggedWorkspaceId
            : (movedIds.last ?? plan.draggedWorkspaceId)
        _ = app.moveWorkspaceToWindow(
            workspaceId: focusId,
            windowId: destinationWindowId,
            focus: true
        )
        selectedWorkspaceIds = Set(movedIds)
        lastSelectionIndex = tabManager.selectedTabId.flatMap { selectedId in
            tabManager.tabs.firstIndex { $0.id == selectedId }
        }
        sidebarSelectionState.selection = .tabs
        return true
    }

    private func clampedCrossWindowTopLevelSlot(
        _ proposedSlot: Int,
        draggedIsPinned: Bool,
        topLevelIds: [UUID],
        pinnedTopLevelIds: Set<UUID>
    ) -> Int {
        let clampedSlot = max(0, min(proposedSlot, topLevelIds.count))
        let pinnedCount = topLevelIds.reduce(into: 0) { count, workspaceId in
            if pinnedTopLevelIds.contains(workspaceId) {
                count += 1
            }
        }
        return draggedIsPinned ? min(clampedSlot, pinnedCount) : max(clampedSlot, pinnedCount)
    }

    private func crossWindowTopLevelWorkspaceIds() -> [UUID] {
        tabManager.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        tabManager.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: nil,
            targetWorkspaceId: nil,
            usesTopLevelRows: true
        )
    }

    private func crossWindowRawInsertIndex(
        forTopLevelSlot slot: Int,
        topLevelIds: [UUID]
    ) -> Int {
        guard slot < topLevelIds.count else { return tabManager.tabs.count }
        let topLevelId = topLevelIds[slot]
        return tabManager.tabs.firstIndex { $0.id == topLevelId } ?? tabManager.tabs.count
    }

    private func syncSidebarSelectionAfterWorkspaceReorder(
        preserving previousSelectionIds: Set<UUID>,
        preferredAnchorWorkspaceId: UUID?
    ) {
        let liveWorkspaceIds = tabManager.tabs.map(\.id)
        let nextSelectionIds = SidebarWorkspaceSelectionSyncPolicy().reconciledSelection(
            previousSelectionIds: previousSelectionIds,
            liveWorkspaceIds: liveWorkspaceIds,
            fallbackSelectedWorkspaceId: tabManager.selectedTabId
        )
        selectedWorkspaceIds = nextSelectionIds
        lastSelectionIndex = SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceReorder(
            preferredAnchorWorkspaceId: preferredAnchorWorkspaceId,
            selectedWorkspaceIds: nextSelectionIds,
            focusedWorkspaceId: tabManager.selectedTabId,
            liveWorkspaceIds: liveWorkspaceIds
        )
    }

    private func sidebarDropIndicatorRowIds(
        draggedWorkspaceId: UUID,
        scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> [UUID] {
        let tabs = tabManager.tabs
        switch scope {
        case .raw:
            return tabs.map(\.id)
        case .topLevel:
            return tabManager.sidebarReorderWorkspaceIds(
                forDraggedWorkspaceId: draggedWorkspaceId,
                usesTopLevelRows: true
            )
        case .group(let groupId):
            guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else {
                return []
            }
            let groupsById = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0) }
            )
            let visibleIds = Set(
                SidebarWorkspaceRenderItem.renderItems(
                    tabs: tabs,
                    groupsById: groupsById
                ).compactMap { item -> UUID? in
                    guard case .workspace(let workspaceId) = item else { return nil }
                    return workspaceId
                }
            )
            return tabs.filter {
                $0.groupId == groupId && visibleIds.contains($0.id)
            }.map(\.id)
        }
    }

    private func findTableContainer(in root: NSView) -> SidebarWorkspaceTableContainerView? {
        if let container = root as? SidebarWorkspaceTableContainerView { return container }
        for subview in root.subviews {
            if let container = findTableContainer(in: subview) { return container }
        }
        return nil
    }
}
