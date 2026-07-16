import AppKit
import Combine
import CmuxFoundation
import CmuxSidebar
import CmuxUpdater
import Foundation
import Observation
import SwiftUI

/// Production SwiftUI ownership bridge for the native workspace sidebar.
///
/// The representable value may be recreated by SwiftUI, but its coordinator
/// keeps the projection source, interaction router, and native footer alive for
/// the lifetime of the mounted sidebar.
@MainActor
struct SidebarAppKitRuntimeHostRepresentable: NSViewControllerRepresentable {
    let updateViewModel: UpdateStateModel
    let fileExplorerState: FileExplorerState
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindow: NSWindow?
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsAgentActivity: Bool
    let enablesModifierShortcutHints: Bool
    let workspaceRowInputProjection: (() -> Void)?

    init(
        updateViewModel: UpdateStateModel,
        fileExplorerState: FileExplorerState,
        windowId: UUID,
        onSendFeedback: @escaping () -> Void,
        onToggleSidebar: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        observedWindow: NSWindow?,
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        cmuxConfigStore: CmuxConfigStore,
        selection: Binding<SidebarSelection>,
        selectedTabIds: Binding<Set<UUID>>,
        lastSidebarSelectionIndex: Binding<Int?>,
        showsAgentActivity: Bool,
        enablesModifierShortcutHints: Bool,
        workspaceRowInputProjection: (() -> Void)? = nil
    ) {
        self.updateViewModel = updateViewModel
        self.fileExplorerState = fileExplorerState
        self.windowId = windowId
        self.onSendFeedback = onSendFeedback
        self.onToggleSidebar = onToggleSidebar
        self.onNewTab = onNewTab
        self.observedWindow = observedWindow
        self.tabManager = tabManager
        self.sidebarUnread = sidebarUnread
        self.cmuxConfigStore = cmuxConfigStore
        _selection = selection
        _selectedTabIds = selectedTabIds
        _lastSidebarSelectionIndex = lastSidebarSelectionIndex
        self.showsAgentActivity = showsAgentActivity
        self.enablesModifierShortcutHints = enablesModifierShortcutHints
        self.workspaceRowInputProjection = workspaceRowInputProjection
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context) -> SidebarAppKitViewController {
        let controller = SidebarAppKitViewController()
        context.coordinator.connect(to: controller)
        return controller
    }

    func updateNSViewController(
        _ nsViewController: SidebarAppKitViewController,
        context: Context
    ) {
        context.coordinator.update(parent: self, controller: nsViewController)
    }

    static func dismantleNSViewController(
        _ nsViewController: SidebarAppKitViewController,
        coordinator: Coordinator
    ) {
        coordinator.disconnect(from: nsViewController)
    }

    @MainActor
    final class Coordinator {
        private var parent: SidebarAppKitRuntimeHostRepresentable
        private let projectionSource: SidebarAppKitProjectionSource
        private weak var controller: SidebarAppKitViewController?
        private weak var observedUpdateViewModel: UpdateStateModel?
        private var updateObservationTask: Task<Void, Never>?
        private var headerUnreadObservationTask: Task<Void, Never>?
        private var defaultsObserver: NSObjectProtocol?
        private var checklistAddObserver: NSObjectProtocol?
        private var dragClearObserver: NSObjectProtocol?
        private var chromeObservers: [NSObjectProtocol] = []
        private var selectionObservers: [NSObjectProtocol] = []
        private var observesFooterPresentation = false
        private let modifierMonitor = SidebarAppKitModifierMonitor()
        private let checklistPopoverController = SidebarAppKitChecklistPopoverController()
        private var checklistStyle = WorkspaceTodoFeature.checklistStyle

        private lazy var interactionCoordinator = SidebarAppKitInteractionCoordinator(
            tabManager: parent.tabManager,
            projectionSource: projectionSource,
            state: makeStateAccess()
        )

        private lazy var dragCoordinator = SidebarAppKitDragCoordinator(
            tabManager: parent.tabManager,
            projectionSource: projectionSource,
            windowId: parent.windowId,
            workspaceDragRegistry: AppDelegate.shared?.sidebarWorkspaceDragRegistry
                ?? SidebarWorkspaceDragRegistry(),
            state: makeDragStateAccess()
        )

        private lazy var contextMenuController = SidebarAppKitContextMenuController(
            tabManager: parent.tabManager,
            projectionSource: projectionSource,
            interactionCoordinator: interactionCoordinator
        )

        private lazy var headerView = SidebarAppKitHeaderView(
            state: makeHeaderState(),
            actions: makeHeaderActions()
        )

        private lazy var footerView = SidebarAppKitFooterView(
            updateModel: parent.updateViewModel,
            presentation: makeFooterPresentation(),
            callbacks: SidebarAppKitFooterView.Callbacks(
                onHelpAction: { [weak self] action in
                    self?.performHelpAction(action)
                },
                onOpenExtensionBrowser: { [weak self] anchorView in
                    self?.openExtensionBrowser(from: anchorView)
                },
                onOpenPricing: {
                    ProUpgradePresenter.present()
                },
                onDismissPro: {
                    ProBadgeStyleStore.shared.isDismissed = true
                },
                onCheckForUpdates: {
                    AppDelegate.shared?.checkForUpdates(nil)
                },
                onCheckForUpdatesInCustomUI: {
                    AppDelegate.shared?.checkForUpdatesInCustomUI()
                },
                onAttemptUpdate: {
                    AppDelegate.shared?.attemptUpdate(nil)
                },
                updateLogPath: {
                    AppDelegate.shared?.updateLogPath ?? ""
                },
                onSendFeedback: { [weak self] in
                    self?.parent.onSendFeedback()
                }
            )
        )

        init(parent: SidebarAppKitRuntimeHostRepresentable) {
            self.parent = parent
            projectionSource = SidebarAppKitProjectionSource(
                tabManager: parent.tabManager,
                sidebarUnread: parent.sidebarUnread,
                cmuxConfigStore: parent.cmuxConfigStore,
                selectedWorkspaceIds: parent.selectedTabIds,
                showsAgentActivity: parent.showsAgentActivity,
                showsModifierShortcutHints: false
            )
        }

        deinit {
            updateObservationTask?.cancel()
            headerUnreadObservationTask?.cancel()
            if let defaultsObserver {
                NotificationCenter.default.removeObserver(defaultsObserver)
            }
            if let checklistAddObserver {
                NotificationCenter.default.removeObserver(checklistAddObserver)
            }
            if let dragClearObserver {
                NotificationCenter.default.removeObserver(dragClearObserver)
            }
            for observer in chromeObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            for observer in selectionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func connect(to controller: SidebarAppKitViewController) {
            self.controller = controller
            projectionSource.onChange = { [weak self, weak controller] change in
                guard let self, let controller else { return }
                if change.structureChanged {
                    controller.apply(self.makeConfiguration())
                } else {
                    controller.reconfigure(itemIDs: change.itemIds)
                    if change.selectionChanged {
                        self.applySelection(to: controller)
                    }
                }
            }
            installFooterObserversIfNeeded()
            installChromeObserversIfNeeded()
            installChecklistAddObserverIfNeeded()
            installDragClearObserverIfNeeded()
            installSelectionObserversIfNeeded()
            startHeaderUnreadObservationIfNeeded()
            refreshHeaderPresentation()
            refreshFooterPresentation()
            modifierMonitor.onChange = { [weak self] isPressed in
                self?.modifierStateChanged(isPressed: isPressed)
            }
            modifierMonitor.start(window: preferredWindow(using: AppDelegate.shared))
            controller.apply(makeConfiguration())
        }

        func update(
            parent: SidebarAppKitRuntimeHostRepresentable,
            controller: SidebarAppKitViewController
        ) {
            self.parent = parent
            self.controller = controller
            interactionCoordinator.updateStateAccess(makeStateAccess())
            dragCoordinator.updateStateAccess(makeDragStateAccess())
            modifierMonitor.updateWindow(preferredWindow(using: AppDelegate.shared))
            modifierStateChanged(isPressed: modifierMonitor.isCommandPressed)
            installFooterObserversIfNeeded()
            installChromeObserversIfNeeded()
            installChecklistAddObserverIfNeeded()
            installDragClearObserverIfNeeded()
            installSelectionObserversIfNeeded()
            headerView.update(actions: makeHeaderActions())
            refreshHeaderPresentation()
            refreshFooterPresentation()
            applySelection(to: controller)
        }

        func disconnect(from controller: SidebarAppKitViewController) {
            guard self.controller === controller else { return }
            projectionSource.onChange = nil
            projectionSource.setVisibleWorkspaceIds([])
            updateObservationTask?.cancel()
            updateObservationTask = nil
            observedUpdateViewModel = nil
            headerUnreadObservationTask?.cancel()
            headerUnreadObservationTask = nil
            if let defaultsObserver {
                NotificationCenter.default.removeObserver(defaultsObserver)
                self.defaultsObserver = nil
            }
            if let checklistAddObserver {
                NotificationCenter.default.removeObserver(checklistAddObserver)
                self.checklistAddObserver = nil
            }
            if let dragClearObserver {
                NotificationCenter.default.removeObserver(dragClearObserver)
                self.dragClearObserver = nil
            }
            for observer in chromeObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            chromeObservers.removeAll()
            for observer in selectionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            selectionObservers.removeAll()
            observesFooterPresentation = false
            modifierMonitor.stop()
            dragCoordinator.cancelActiveDrag()
            checklistPopoverController.close()
            controller.prepareForRemoval()
            self.controller = nil
        }

        private func makeConfiguration() -> SidebarAppKitConfiguration {
            SidebarAppKitConfiguration(
                renderItems: projectionSource.renderItems,
                selectedWorkspaceIDs: parent.selectedTabIds,
                activeWorkspaceID: parent.tabManager.selectedTabId,
                workspaceSnapshot: { [weak self] workspaceId in
                    guard let self else { return nil }
                    #if DEBUG
                    self.parent.workspaceRowInputProjection?()
                    #endif
                    return self.projectionSource.workspaceSnapshot(workspaceId: workspaceId)
                },
                groupSnapshot: { [weak self] groupId in
                    self?.projectionSource.groupSnapshot(groupId: groupId)
                },
                workspaceActions: { [weak self] workspaceId in
                    self?.makeWorkspaceActions(workspaceId: workspaceId) ?? .none
                },
                groupActions: { [weak self] groupId in
                    self?.makeGroupActions(groupId: groupId) ?? .none
                },
                interactions: SidebarAppKitConfiguration.InteractionHandlers(
                    onSelectionChanged: { [weak self] primaryWorkspaceId, modifiers in
                        guard let primaryWorkspaceId else { return }
                        self?.interactionCoordinator.activateWorkspace(
                            primaryWorkspaceId,
                            modifiers: modifiers
                        )
                    },
                    onHoveredItemChanged: { _ in },
                    onMiddleClick: { [weak self] item, _ in
                        self?.interactionCoordinator.closeWorkspaceFromMiddleClick(
                            item.rowWorkspaceId
                        )
                    },
                    contextMenuProvider: { [weak self] item, event in
                        self?.contextMenuController.menu(for: item, event: event)
                    },
                    onEmptyAreaDoubleClick: { [weak self] in
                        self?.interactionCoordinator.addWorkspaceAtEnd()
                    },
                    emptyAreaContextMenuProvider: { [weak self] _ in
                        self?.contextMenuController.emptyAreaMenu()
                    },
                    onVisibleWorkspaceIDsChanged: { [weak self] workspaceIds in
                        self?.projectionSource.setVisibleWorkspaceIds(workspaceIds)
                    }
                ),
                dragHandlers: dragCoordinator.dragHandlers(),
                headerView: headerView,
                footerView: footerView
            )
        }

        private func makeWorkspaceActions(
            workspaceId: UUID
        ) -> SidebarAppKitWorkspaceCellView.Actions {
            SidebarAppKitWorkspaceCellView.Actions(
                onActivate: { [weak self] in
                    self?.interactionCoordinator.activateWorkspace(
                        workspaceId,
                        modifiers: NSEvent.modifierFlags
                    )
                },
                onMoveUp: { [weak self] in
                    self?.interactionCoordinator.moveWorkspace(workspaceId, by: -1)
                },
                onMoveDown: { [weak self] in
                    self?.interactionCoordinator.moveWorkspace(workspaceId, by: 1)
                },
                onCommitRename: { [weak self] title in
                    self?.interactionCoordinator.renameWorkspace(workspaceId, to: title)
                },
                onClose: { [weak self] in
                    self?.interactionCoordinator.closeWorkspace(workspaceId)
                },
                onOpenMetadataURL: { [weak self] url in
                    self?.interactionCoordinator.openMetadataURL(
                        url,
                        fromWorkspace: workspaceId
                    )
                },
                onOpenPullRequest: { [weak self] url in
                    self?.interactionCoordinator.openURL(url, fromWorkspace: workspaceId)
                },
                onOpenPort: { [weak self] port in
                    self?.interactionCoordinator.openPort(port, fromWorkspace: workspaceId)
                },
                checklistStyle: WorkspaceTodoFeature.checklistStyle,
                onOpenChecklist: { [weak self] anchorView in
                    self?.toggleChecklist(workspaceId: workspaceId, anchorView: anchorView)
                },
                resolveChecklistWorkspace: { [weak self] in
                    self?.projectionSource.workspaceById[workspaceId]
                },
                onChecklistHeightChanged: { [weak self] in
                    self?.controller?.noteChecklistHeightChanged(for: workspaceId)
                },
                onReconnectRemote: { [weak self] in
                    self?.interactionCoordinator.reconnectRemoteWorkspace(workspaceId)
                },
                onCopyRemoteError: { [weak self] text in
                    self?.interactionCoordinator.copyRemoteError(text)
                }
            )
        }

        private func makeGroupActions(
            groupId: UUID
        ) -> SidebarAppKitGroupCellView.Actions {
            SidebarAppKitGroupCellView.Actions(
                onActivate: { [weak self] in
                    self?.interactionCoordinator.focusGroupAnchor(groupId)
                },
                onToggleCollapsed: { [weak self] in
                    self?.interactionCoordinator.toggleGroupCollapsed(groupId)
                },
                onAddWorkspace: { [weak self] in
                    self?.interactionCoordinator.addWorkspace(toGroup: groupId)
                },
                onContextMenu: { [weak self] event in
                    self?.contextMenuController.groupAddButtonMenu(
                        groupId: groupId,
                        event: event
                    )
                }
            )
        }

        private func makeStateAccess() -> SidebarAppKitInteractionCoordinator.StateAccess {
            SidebarAppKitInteractionCoordinator.StateAccess(
                selectedWorkspaceIds: { [weak self] in
                    self?.parent.selectedTabIds ?? []
                },
                setSelectedWorkspaceIds: { [weak self] ids in
                    self?.parent.selectedTabIds = ids
                },
                lastSelectionIndex: { [weak self] in
                    self?.parent.lastSidebarSelectionIndex
                },
                setLastSelectionIndex: { [weak self] index in
                    self?.parent.lastSidebarSelectionIndex = index
                },
                selectTabsPage: { [weak self] in
                    self?.parent.selection = .tabs
                },
                showsAgentActivity: { [weak self] in
                    self?.parent.showsAgentActivity ?? false
                }
            )
        }

        private func makeDragStateAccess() -> SidebarAppKitDragCoordinator.StateAccess {
            SidebarAppKitDragCoordinator.StateAccess(
                selectedWorkspaceIds: { [weak self] in
                    self?.parent.selectedTabIds ?? []
                },
                setSelectedWorkspaceIds: { [weak self] ids in
                    self?.parent.selectedTabIds = ids
                },
                lastSelectionIndex: { [weak self] in
                    self?.parent.lastSidebarSelectionIndex
                },
                setLastSelectionIndex: { [weak self] index in
                    self?.parent.lastSidebarSelectionIndex = index
                },
                selectTabsPage: { [weak self] in
                    self?.parent.selection = .tabs
                }
            )
        }

        private func applySelection(to controller: SidebarAppKitViewController) {
            controller.updateSelection(
                selectedWorkspaceIDs: parent.selectedTabIds,
                activeWorkspaceID: parent.tabManager.selectedTabId
            )
        }

        private func modifierStateChanged(isPressed: Bool) {
            projectionSource.updateExternalState(
                selectedWorkspaceIds: parent.selectedTabIds,
                showsAgentActivity: parent.showsAgentActivity,
                showsModifierShortcutHints: parent.enablesModifierShortcutHints && isPressed
            )
            refreshFooterPresentation()
        }

        private func installFooterObserversIfNeeded() {
            if observedUpdateViewModel !== parent.updateViewModel {
                updateObservationTask?.cancel()
                let model = parent.updateViewModel
                observedUpdateViewModel = model
                updateObservationTask = Task { @MainActor [weak self, weak model] in
                    guard let model else { return }
                    for await _ in model.stateChanges() {
                        guard !Task.isCancelled, let self else { return }
                        self.refreshFooterPresentation()
                    }
                }
            }

            if defaultsObserver == nil {
                defaultsObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reconcileChecklistStyle()
                        self?.refreshHeaderPresentation()
                        self?.refreshFooterPresentation()
                    }
                }
            }

            if !observesFooterPresentation {
                observesFooterPresentation = true
                observeFooterPresentation()
            }
        }

        private func reconcileChecklistStyle() {
            let nextStyle = WorkspaceTodoFeature.checklistStyle
            guard nextStyle != checklistStyle else { return }
            checklistStyle = nextStyle
            checklistPopoverController.close()
            projectionSource.collapseAllChecklists()
        }

        private func installChromeObserversIfNeeded() {
            guard chromeObservers.isEmpty else { return }
            let center = NotificationCenter.default
            for name in [
                Notification.Name.tabManagerFocusHistoryRevisionDidChange,
                Notification.Name.cmuxNotificationsPopoverVisibilityDidChange,
                NSWindow.didBecomeKeyNotification,
            ] {
                chromeObservers.append(center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshHeaderPresentation()
                    }
                })
            }
        }

        private func installChecklistAddObserverIfNeeded() {
            guard checklistAddObserver == nil else { return }
            checklistAddObserver = NotificationCenter.default.addObserver(
                forName: .workspaceChecklistAddItemRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let workspaceId = notification.userInfo?[WorkspaceTodoActions.workspaceIdUserInfoKey]
                    as? UUID else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.projectionSource.workspaceById[workspaceId] != nil else {
                        return
                    }
                    self.presentChecklistAddField(workspaceId: workspaceId)
                }
            }
        }

        private func toggleChecklist(workspaceId: UUID, anchorView: NSView) {
            guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
            switch WorkspaceTodoFeature.checklistStyle {
            case .popover:
                projectionSource.setChecklistExpanded(false, workspaceId: workspaceId)
                _ = checklistPopoverController.toggle(
                    workspace: workspace,
                    relativeTo: anchorView,
                    focusAddField: false
                )
            case .inline:
                checklistPopoverController.close()
                let shouldExpand = !projectionSource.isChecklistExpanded(workspaceId: workspaceId)
                projectionSource.setChecklistExpanded(shouldExpand, workspaceId: workspaceId)
                if shouldExpand,
                   controller?.checklistAnchorView(for: workspaceId, makeVisible: false)
                    is SidebarAppKitGroupCellView {
                    projectionSource.setChecklistExpanded(false, workspaceId: workspaceId)
                    if let fallbackAnchor = controller?.checklistAnchorView(for: workspaceId) {
                        _ = checklistPopoverController.present(
                            workspace: workspace,
                            relativeTo: fallbackAnchor,
                            focusAddField: false
                        )
                    }
                }
            }
        }

        private func presentChecklistAddField(workspaceId: UUID) {
            guard let workspace = projectionSource.workspaceById[workspaceId],
                  let controller else {
                return
            }
            switch WorkspaceTodoFeature.checklistStyle {
            case .popover:
                projectionSource.setChecklistExpanded(false, workspaceId: workspaceId)
                guard let anchor = controller.checklistAnchorView(for: workspaceId) else {
                    NSSound.beep()
                    return
                }
                if !checklistPopoverController.present(
                    workspace: workspace,
                    relativeTo: anchor,
                    focusAddField: true
                ) {
                    NSSound.beep()
                }
            case .inline:
                checklistPopoverController.close()
                projectionSource.setChecklistExpanded(true, workspaceId: workspaceId)
                if !controller.focusInlineChecklistAddField(for: workspaceId) {
                    projectionSource.setChecklistExpanded(false, workspaceId: workspaceId)
                    guard let anchor = controller.checklistAnchorView(for: workspaceId),
                          checklistPopoverController.present(
                            workspace: workspace,
                            relativeTo: anchor,
                            focusAddField: true
                          ) else {
                        NSSound.beep()
                        return
                    }
                }
            }
        }

        private func installDragClearObserverIfNeeded() {
            guard dragClearObserver == nil else { return }
            dragClearObserver = NotificationCenter.default.addObserver(
                forName: SidebarDragLifecycleNotification.requestClear,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dragCoordinator.cancelActiveDrag()
                }
            }
        }

        private func installSelectionObserversIfNeeded() {
            guard selectionObservers.isEmpty else { return }
            let center = NotificationCenter.default
            selectionObservers.append(center.addObserver(
                forName: SidebarMultiSelectionDidHideEvent.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleMultiSelectionDidHide(notification)
                }
            })
            selectionObservers.append(center.addObserver(
                forName: SidebarMultiSelectionShouldCollapseEvent.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleMultiSelectionShouldCollapse(notification)
                }
            })
        }

        private func handleMultiSelectionDidHide(_ notification: Notification) {
            guard let model = notification.object as? SidebarMultiSelectionModel,
                  model === parent.tabManager.sidebarMultiSelection,
                  let event = SidebarMultiSelectionDidHideEvent(notification) else {
                return
            }
            var next = parent.selectedTabIds.subtracting(event.hiddenWorkspaceIds)
            if let focusedId = event.focusedWorkspaceId {
                next.insert(focusedId)
                parent.lastSidebarSelectionIndex = projectionSource.workspaceIndexById[focusedId]
            }
            applyExternalSelection(next)
        }

        private func handleMultiSelectionShouldCollapse(_ notification: Notification) {
            guard let model = notification.object as? SidebarMultiSelectionModel,
                  model === parent.tabManager.sidebarMultiSelection,
                  let event = SidebarMultiSelectionShouldCollapseEvent(notification) else {
                return
            }
            let focusedId = event.focusedWorkspaceId
            let next: Set<UUID> = projectionSource.workspaceById[focusedId] == nil
                ? []
                : [focusedId]
            parent.lastSidebarSelectionIndex = projectionSource.workspaceIndexById[focusedId]
            applyExternalSelection(next)
        }

        private func applyExternalSelection(_ workspaceIds: Set<UUID>) {
            guard workspaceIds != parent.selectedTabIds else { return }
            parent.selectedTabIds = workspaceIds
            parent.tabManager.setSidebarSelectedWorkspaceIds(workspaceIds)
            projectionSource.updateExternalState(
                selectedWorkspaceIds: workspaceIds,
                showsAgentActivity: parent.showsAgentActivity
            )
            if let controller {
                applySelection(to: controller)
            }
        }

        private func startHeaderUnreadObservationIfNeeded() {
            guard headerUnreadObservationTask == nil else { return }
            let unread = parent.sidebarUnread
            headerUnreadObservationTask = Task { @MainActor [weak self, weak unread] in
                guard let unread else { return }
                for await _ in unread.$totalUnreadCount.values {
                    guard !Task.isCancelled, let self else { return }
                    self.refreshHeaderPresentation()
                }
            }
        }

        private func refreshHeaderPresentation() {
            headerView.update(state: makeHeaderState())
        }

        private func makeHeaderState() -> SidebarAppKitHeaderView.State {
            let window = preferredWindow(using: AppDelegate.shared)
            let availability = focusHistoryNavigationAvailability(preferredWindow: window)
            return SidebarAppKitHeaderView.State(
                canNavigateBack: availability.canNavigateBack,
                canNavigateForward: availability.canNavigateForward,
                unreadNotificationCount: parent.sidebarUnread.totalUnreadCount,
                isNotificationsPresented: NotificationsPopoverVisibilityState.shared.isShown(
                    in: window?.windowNumber
                ),
                showsControls: WorkspacePresentationModeSettings.isMinimal()
            )
        }

        private func makeHeaderActions() -> SidebarAppKitHeaderView.Actions {
            SidebarAppKitHeaderView.Actions(
                onToggleSidebar: { [weak self] in
                    self?.parent.onToggleSidebar()
                },
                onToggleNotifications: { anchorView in
                    AppDelegate.shared?.toggleNotificationsPopover(
                        animated: true,
                        anchorView: anchorView
                    )
                },
                onNewWorkspace: { [weak self] in
                    self?.parent.onNewTab()
                },
                onCloudVM: { anchorView in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                        anchorView: anchorView,
                        debugSource: "sidebar.appKit.header.cloudMenu"
                    )
                },
                onFocusHistoryBack: { [weak self] in
                    guard self?.parent.tabManager.navigateBack() == true else {
                        NSSound.beep()
                        return
                    }
                },
                onFocusHistoryForward: { [weak self] in
                    guard self?.parent.tabManager.navigateForward() == true else {
                        NSSound.beep()
                        return
                    }
                },
                onContextMenu: { control, anchorView, event in
                    switch control {
                    case .toggleSidebar:
                        CmuxExtensionSidebarSelection.showMenu(
                            anchorView: anchorView,
                            event: event
                        )
                    case .newWorkspace, .cloudVM:
                        _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                            anchorView: anchorView,
                            event: event,
                            debugSource: "sidebar.appKit.header.contextMenu"
                        )
                    case .focusHistoryBack:
                        _ = AppDelegate.shared?.showFocusHistoryContextMenu(
                            anchorView: anchorView,
                            event: event,
                            direction: .back
                        )
                    case .focusHistoryForward:
                        _ = AppDelegate.shared?.showFocusHistoryContextMenu(
                            anchorView: anchorView,
                            event: event,
                            direction: .forward
                        )
                    case .showNotifications:
                        break
                    }
                }
            )
        }

        private func observeFooterPresentation() {
            withObservationTracking {
                _ = CmuxFeatureFlags.shared.isProUpgradeUIEnabled
                _ = ProBadgeStyleStore.shared.current
                _ = ProBadgeStyleStore.shared.isDismissed
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.observesFooterPresentation else { return }
                    self.refreshFooterPresentation()
                    self.observeFooterPresentation()
                }
            }
        }

        private func refreshFooterPresentation() {
            guard controller != nil else { return }
            footerView.apply(presentation: makeFooterPresentation())
        }

        private func makeFooterPresentation() -> SidebarAppKitFooterView.Presentation {
            let proStore = ProBadgeStyleStore.shared
            #if DEBUG
            let showsDevBuildBanner = DevBuildBannerDebugSettings().showSidebarBanner
            #else
            let showsDevBuildBanner = false
            #endif
            return SidebarAppKitFooterView.Presentation(
                showsExtensionButton: CmuxExtensionSidebarSelection.isEnabled,
                showsProButton: CmuxFeatureFlags.shared.isProUpgradeUIEnabled
                    && !proStore.isDismissed,
                proButtonTitle: proStore.current.text ?? String(
                    localized: "sidebar.pro.badge",
                    defaultValue: "Upgrade"
                ),
                showsUpdateButton: parent.updateViewModel.showsPill,
                updateButtonTitle: parent.updateViewModel.text,
                showsShortcutDiscoveryButton: parent.enablesModifierShortcutHints
                    && modifierMonitor.isCommandPressed,
                showsDevBuildBanner: showsDevBuildBanner
            )
        }

        private func performHelpAction(_ action: SidebarAppKitHelpMenuController.Action) {
            switch action {
            case .welcome:
                AppDelegate.shared?.openWelcomeWorkspace()
            case .keyboardShortcuts:
                if let appDelegate = AppDelegate.shared {
                    appDelegate.openPreferencesWindow(
                        debugSource: "sidebarAppKit.help.keyboardShortcuts",
                        navigationTarget: .keyboardShortcuts
                    )
                } else {
                    AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
                }
            case .importBrowserData:
                BrowserDataImportCoordinator.shared.presentImportDialog()
            case .docs:
                openURL("https://cmux.com/docs")
            case .changelog:
                openURL("https://cmux.com/docs/changelog")
            case .github:
                openURL("https://github.com/manaflow-ai/cmux")
            case .githubIssues:
                openURL("https://github.com/manaflow-ai/cmux/issues")
            case .discord:
                openURL("https://discord.gg/xsgFEVrWCZ")
            }
        }

        private func openExtensionBrowser(from anchorView: NSView) {
            _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                from: anchorView,
                title: String(
                    localized: "sidebar.extensions.browser.title",
                    defaultValue: "Sidebar Extensions"
                )
            )
        }

        private func openURL(_ string: String) {
            guard let url = URL(string: string) else { return }
            NSWorkspace.shared.open(url)
        }

        private func preferredWindow(using appDelegate: AppDelegate?) -> NSWindow? {
            parent.observedWindow ?? appDelegate?.mainWindow(for: parent.windowId)
        }
    }
}
