import AppKit
import Bonsplit
import CmuxSettings
import Foundation

enum DockBatchCloseConfirmationPolicy: Sendable {
    case tabsRequiringConfirmation
    case allTabs
}

extension DockSplitStore {
    func splitTabBar(
        _ controller: BonsplitController,
        didRequestTabContextAction action: TabContextAction,
        for tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        guard controller === bonsplitController,
              let panelId = surfaceIdToPanelId[tab.id],
              panels[panelId] != nil else {
            return
        }

        switch action {
        case .rename:
            _ = promptRenameDockSurface(
                tabId: tab.id,
                presentingWindow: dockContextMenuWindow
            )
        case .clearName:
            _ = setDockPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            copyDockIdentifiers(panelId: panelId, paneId: pane)
        case .closeToLeft:
            _ = closeDockTabs(
                dockTabIds(toLeftOf: tab.id, inPane: pane),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .closeToRight:
            _ = closeDockTabs(
                dockTabIds(toRightOf: tab.id, inPane: pane),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .closeOthers:
            _ = closeDockTabs(
                controller.tabs(inPane: pane).lazy
                    .filter { $0.id != tab.id }
                    .map(\.id),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .move:
            if let destination = dockTabMoveDestinations(
                for: tab.id
            ).first {
                splitTabBar(
                    controller,
                    didRequestTabMoveToDestination: destination.id,
                    for: tab,
                    inPane: pane
                )
            }
        case .moveToNewWorkspace:
            _ = AppDelegate.shared?.moveDockSurfaceToNewWorkspace(
                sourceDock: self,
                panelId: panelId,
                focus: true,
                focusWindow: false
            )
        case .moveToLeftPane:
            moveDockContextTab(
                panelId: panelId,
                movement: .left
            )
        case .moveToRightPane:
            moveDockContextTab(
                panelId: panelId,
                movement: .right
            )
        case .newTerminalToRight:
            createDockContextSurfaceToRight(
                kind: .terminal,
                anchorTabId: tab.id,
                paneId: pane
            )
        case .newBrowserToRight:
            createDockContextSurfaceToRight(
                kind: .browser,
                anchorTabId: tab.id,
                paneId: pane
            )
        case .reload:
            browserPanel(for: panelId)?.reload()
        case .toggleAudioMute:
            toggleDockBrowserMute(panelId: panelId, tabId: tab.id)
        case .duplicate:
            _ = duplicateBrowserToRight(panelId: panelId)
        case .togglePin:
            setDockTabPinned(tabId: tab.id, pinned: !tab.isPinned)
        case .markAsRead:
            setDockTabUnread(panelId: panelId, tabId: tab.id, unread: false)
        case .markAsUnread:
            setDockTabUnread(panelId: panelId, tabId: tab.id, unread: true)
        case .toggleZoom:
            _ = toggleDockPaneZoom(inPane: pane)
        case .toggleFullWidthTab:
            _ = toggleDockFullWidthTab(panelId: panelId)
        case .disconnectRemote,
             .forkConversation,
             .forkConversationRight,
             .forkConversationLeft,
             .forkConversationTop,
             .forkConversationBottom,
             .forkConversationNewTab,
             .forkConversationNewWorkspace:
            break
        @unknown default:
            break
        }
    }

    @discardableResult
    func closeDockTabs<S: Sequence>(
        _ tabIds: S,
        inPane paneId: PaneID,
        confirmationPolicy: DockBatchCloseConfirmationPolicy
    ) -> Bool where S.Element == TabID {
        let candidates = tabIds.compactMap { tabId -> (
            tabId: TabID,
            panelId: UUID,
            title: String,
            needsConfirmation: Bool
        )? in
            guard let tab = bonsplitController.tab(tabId),
                  !tab.isPinned,
                  let panelId = surfaceIdToPanelId[tabId],
                  let panel = panels[panelId] else {
                return nil
            }
            return (
                tabId,
                panelId,
                CloseOtherTabsConfirmationPrompt.displayTitle(
                    tab.title
                ),
                dockPanelNeedsConfirmClose(panel)
            )
        }
        guard !candidates.isEmpty else { return true }

        let manager = dockCloseConfirmationManager()
        guard manager?.isCloseConfirmationInFlight != true else {
            return true
        }
        let needsConfirmation: Bool
        switch confirmationPolicy {
        case .tabsRequiringConfirmation:
            needsConfirmation = candidates.contains {
                $0.needsConfirmation
            }
        case .allTabs:
            needsConfirmation = true
        }
        let warningStore = CloseTabWarningStore(
            defaults: manager?.closeTabWarningDefaults ?? .standard
        )
        if warningStore.shouldConfirmClose(
            requiresConfirmation: needsConfirmation,
            source: .shortcut
        ) {
            guard let manager else { return false }
            let prompt = CloseOtherTabsConfirmationPrompt(
                titles: candidates.map(\.title)
            )
            guard manager.confirmClose(
                title: prompt.title,
                message: prompt.message,
                scrollableDetails: prompt.details,
                acceptCmdD: false
            ) else {
                return true
            }
        }

        stageDockClosedPanelHistory(
            tabIds: Set(candidates.map(\.tabId)),
            inPane: paneId
        )
        for candidate in candidates {
            if !closePanel(
                candidate.panelId,
                force: needsConfirmation
            ) {
                discardDockClosedPanelHistory(tabId: candidate.tabId)
            }
        }
        return true
    }

    private var dockContextMenuWindow: NSWindow? {
        guard let app = AppDelegate.shared,
              let manager = app.dockReferenceTabManager(for: self),
              let windowId = app.windowId(for: manager) else {
            return NSApp.keyWindow ?? NSApp.mainWindow
        }
        return app.mainWindow(for: windowId)
    }

    private func copyDockIdentifiers(
        panelId: UUID,
        paneId: PaneID
    ) {
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText
                .makeWorkspacePaneSurfaceIdentifiers(
                    workspaceId: workspaceId,
                    paneId: paneId.id,
                    surfaceId: panelId,
                    includeRefs: true
                )
        )
    }

    private func dockTabIds(
        toLeftOf anchorTabId: TabID,
        inPane paneId: PaneID
    ) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }) else {
            return []
        }
        return tabs[..<index].map(\.id)
    }

    private func dockTabIds(
        toRightOf anchorTabId: TabID,
        inPane paneId: PaneID
    ) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }), index + 1 < tabs.count else {
            return []
        }
        return tabs[(index + 1)...].map(\.id)
    }

    private func moveDockContextTab(
        panelId: UUID,
        movement: SurfacePaneMovement
    ) {
        focusPanel(panelId)
        _ = performShortcutCommand(
            .moveSurfaceToPane(
                movement,
                allowMissingDestinationSplit: false
            )
        )
    }

    private func createDockContextSurfaceToRight(
        kind: DockSurfaceKind,
        anchorTabId: TabID,
        paneId: PaneID
    ) {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }) else {
            return
        }
        let sourcePanelId = surfaceIdToPanelId[anchorTabId]
        let sourceBrowser = sourcePanelId.flatMap {
            browserPanel(for: $0)
        }
        guard let panelId = newSurface(
            kind: kind,
            inPane: paneId,
            sourcePanelId: sourcePanelId,
            focus: true,
            preferredProfileID: sourceBrowser?.profileID,
            websiteDataStore:
                sourceBrowser?.explicitEphemeralWebsiteDataStoreForSibling
        ),
        let newTabId = surfaceId(forPanelId: panelId) else {
            return
        }
        _ = bonsplitController.reorderTab(
            newTabId,
            toIndex: anchorIndex + 1
        )
        if let browser = browserPanel(for: panelId) {
            _ = AppDelegate.shared?.focusBrowserAddressBar(in: browser)
        }
    }

    private func toggleDockBrowserMute(
        panelId: UUID,
        tabId: TabID
    ) {
        guard let browser = browserPanel(for: panelId),
              browser.toggleMute() else {
            NSSound.beep()
            return
        }
        bonsplitController.updateTab(
            tabId,
            isAudioMuted: browser.isMuted
        )
    }

    private func setDockTabPinned(
        tabId: TabID,
        pinned: Bool
    ) {
        guard let paneId = paneId(forTabId: tabId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        let tabs = bonsplitController.tabs(
            inPane: paneId
        )
        let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        for (index, tab) in ordered.enumerated() {
            _ = bonsplitController.reorderTab(tab.id, toIndex: index)
        }
    }

    @discardableResult
    func setDockPanelPinned(
        panelId: UUID,
        pinned: Bool
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        setDockTabPinned(tabId: tabId, pinned: pinned)
        return true
    }

    private func paneId(forTabId tabId: TabID) -> PaneID? {
        bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains {
                $0.id == tabId
            }
        }
    }

    @discardableResult
    func toggleDockFullWidthTab(panelId: UUID) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let paneId = paneId(forTabId: tabId) else {
            return false
        }
        return bonsplitController.requestTabFullWidthToggle(
            for: tabId,
            inPane: paneId
        )
    }

    func panelIsUnread(_ panelId: UUID) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let tab = bonsplitController.tab(tabId) else {
            return false
        }
        let notificationStore = resolvedNotificationStore()
        return tab.showsNotificationBadge ||
            manualUnreadPanelIds.contains(panelId) ||
            notificationStore?.hasManualUnread(
                forTabId: workspaceId,
                surfaceId: panelId
            ) == true ||
            notificationStore?.hasUnreadNotification(
                forTabId: workspaceId,
                surfaceId: panelId
            ) == true
    }

    @discardableResult
    func togglePanelUnread(_ panelId: UUID) -> Bool {
        setDockPanelUnread(
            panelId: panelId,
            unread: !panelIsUnread(panelId)
        )
    }

    private func setDockTabUnread(
        panelId: UUID,
        tabId: TabID,
        unread: Bool
    ) {
        adoptManualUnreadState(unread, panelId: panelId)
        let notificationStore = resolvedNotificationStore()
        if !unread {
            notificationStore?.markRead(
                forTabId: workspaceId,
                surfaceId: panelId
            )
            notificationStore?.clearFocusedReadIndicator(
                forTabId: workspaceId,
                surfaceId: panelId
            )
        }
        bonsplitController.updateTab(
            tabId,
            showsNotificationBadge: unread
        )
    }

    @discardableResult
    func setDockPanelUnread(
        panelId: UUID,
        unread: Bool
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        setDockTabUnread(
            panelId: panelId,
            tabId: tabId,
            unread: unread
        )
        return true
    }

    /// Adopts durable unread state through the authority for this Dock scope.
    /// Window Docks use their injected notification store; legacy workspace
    /// Docks retain local state because they do not have a window-Dock target.
    func adoptManualUnreadState(
        _ unread: Bool,
        panelId: UUID
    ) {
        if scope == .global {
            manualUnreadPanelIds.remove(panelId)
            applyWindowDockUnreadState(unread, panelId: panelId)
            return
        }
        if unread {
            manualUnreadPanelIds.insert(panelId)
        } else {
            manualUnreadPanelIds.remove(panelId)
        }
    }
}
