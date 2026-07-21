import AppKit
import CmuxCore

extension Workspace {
    func browserPanelIncludingDock(for panelId: UUID) -> BrowserPanel? {
        browserPanel(for: panelId) ?? dockBrowserPanel(for: panelId)
    }

    func browserPanelIncludingDock(owning webView: CmuxWebView) -> BrowserPanel? {
        if let panel = panels.values
            .compactMap({ $0 as? BrowserPanel })
            .first(where: { $0.webView === webView }) {
            return panel
        }
        if let panel = _dockSplit?.panels.values
            .compactMap({ $0 as? BrowserPanel })
            .first(where: { $0.webView === webView }) {
            return panel
        }
        return floatingDocks.lazy.compactMap { dock in
            dock.store.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView })
        }.first
    }

    func dockBrowserPanel(for panelId: UUID) -> BrowserPanel? {
        guard let store = DockSplitStore.owner(containingPanel: panelId),
              ownsDockStore(store) else { return nil }
        return store.browserPanel(for: panelId)
    }

    func dockBrowserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        if let panel = _dockSplit?.browserPanel(owning: responder, in: window) { return panel }
        return floatingDocks.lazy.compactMap {
            $0.store.browserPanel(owning: responder, in: window)
        }.first
    }

    func containsPanelIncludingDocks(_ panelId: UUID) -> Bool {
        if panels[panelId] != nil, surfaceIdFromPanelId(panelId) != nil { return true }
        guard let store = DockSplitStore.owner(containingPanel: panelId) else { return false }
        return ownsDockStore(store)
    }

    private func ownsDockStore(_ store: DockSplitStore) -> Bool {
        _dockSplit === store || floatingDocks.contains { $0.store === store }
    }

    func containsDockPane(_ paneId: UUID) -> Bool {
        _dockSplit?.containsPane(paneId) ?? false
    }

    func containsDockPanel(_ panelId: UUID) -> Bool {
        _dockSplit?.containsPanel(panelId) ?? false
    }

    var focusedDockPanelId: UUID? {
        _dockSplit?.focusedPanelId
    }

    @discardableResult
    func closeDockPanel(_ panelId: UUID, force: Bool = false) -> Bool {
        _dockSplit?.closePanel(panelId, force: force) ?? false
    }

    @discardableResult
    func closeDockPanelAndClearNotifications(_ panelId: UUID, force: Bool = false) -> Bool {
        guard closeDockPanel(panelId, force: force) else { return false }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        return true
    }

    func isDockAutosaveClosePending(panelId: UUID) -> Bool {
        _dockSplit?.isAutosaveClosePending(panelId: panelId) ?? false
    }

    func openDockBrowserLinkInNewTab(panel: BrowserPanel, seed: BrowserNewTabNavigationSeed) -> Bool {
        guard let dock = DockSplitStore.owner(containingPanel: panel.id),
              ownsDockStore(dock),
              let paneId = dock.paneId(forPanelId: panel.id) else { return false }
        return dock.newSurface(
            kind: .browser,
            inPane: paneId,
            url: seed.url,
            initialRequest: seed.initialRequest,
            focus: true,
            preferredProfileID: panel.profileID,
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce
        ) != nil
    }

    static func openDockBrowserLinkInNewTabIfNeeded(panel: BrowserPanel, seed: BrowserNewTabNavigationSeed) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        if let dock = app.windowDockContainingPanel(panel.id),
           dock.browserPanel(for: panel.id) === panel,
           let paneId = dock.paneId(forPanelId: panel.id) {
            return dock.newSurface(
                kind: .browser,
                inPane: paneId,
                url: seed.url,
                initialRequest: seed.initialRequest,
                focus: true,
                preferredProfileID: panel.profileID,
                bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce
            ) != nil
        }
        guard let manager = app.tabManagerFor(tabId: panel.workspaceId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else { return false }
        return workspace.openDockBrowserLinkInNewTab(panel: panel, seed: seed)
    }
}

extension AppDelegate {
    @discardableResult
    func closeFocusedDockPanelForCommand(preferredWindow: NSWindow?) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        guard context.keyboardFocusCoordinator.activeRightSidebarMode == .dock else { return false }
        if let windowDock = existingWindowDock(forWindowId: context.windowId) {
            guard let panelId = windowDock.focusedPanelId else { return true }
            if windowDock.closePanel(panelId, force: false) {
                notificationStore?.clearNotifications(forTabId: windowDock.workspaceId, surfaceId: panelId)
            }
            return true
        }
        guard let workspace = context.tabManager.selectedWorkspace,
              let panelId = workspace.focusedDockPanelId else { return true }
        _ = workspace.closeDockPanelAndClearNotifications(panelId, force: false)
        return true
    }
}

extension DockSplitStore {
    /// Builds a Dock browser panel with the workspace's remote-browser settings.
    func makeBrowserPanel(
        url: URL?,
        initialRequest: URLRequest? = nil,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel {
        let settings = currentRemoteBrowserSettings()
        let panel = BrowserPanel(
            workspaceId: workspaceId,
            profileID: preferredProfileID,
            initialURL: url,
            initialRequest: initialRequest,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: settings.proxyEndpoint,
            bypassRemoteProxy: settings.bypassRemoteProxy,
            isRemoteWorkspace: settings.isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: settings.remoteWebsiteDataStoreIdentifier
        )
        panel.setRemoteWorkspaceStatus(settings.remoteStatus)
        panel.webViewDidRequestClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard self.browserPanel(for: panel.id) === panel else { return }
#if DEBUG
            cmuxDebugLog(
                "dock.browser.close.requestedByPage ws=\(self.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5))"
            )
#endif
            _ = self.closePanel(panel.id, force: true)
        }
        return panel
    }

    @discardableResult
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else { return false }
        if force { forceCloseDockTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId)
        let pending = pendingAutosaveCloseDockTabIds.contains(tabId)
        if force && !closed && !pending { forceCloseDockTabIds.remove(tabId) }
        return closed || pending
    }

    func isAutosaveClosePending(panelId: UUID) -> Bool {
        surfaceId(forPanelId: panelId).map(pendingAutosaveCloseDockTabIds.contains) ?? false
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        for browserPanel in dockBrowserPanels {
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
    }

    func applyRemoteWorkspaceStatus(_ status: BrowserRemoteWorkspaceStatus?) {
        for browserPanel in dockBrowserPanels {
            browserPanel.setRemoteWorkspaceStatus(status)
        }
    }

    private var dockBrowserPanels: [BrowserPanel] {
        bonsplitController.allTabIds.compactMap { panel(for: $0) as? BrowserPanel }
    }
}
