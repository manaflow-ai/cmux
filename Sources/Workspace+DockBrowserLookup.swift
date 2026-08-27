import AppKit
import CmuxBrowser
import CmuxCore
import CmuxPanes
import WebKit

extension Workspace {
    func browserPanelIncludingDock(for panelId: UUID) -> BrowserPanel? {
        browserPanel(for: panelId) ?? dockBrowserPanel(for: panelId)
    }

    func dockBrowserPanel(for panelId: UUID) -> BrowserPanel? {
        _dockSplit?.browserPanel(for: panelId)
    }

    func dockBrowserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        _dockSplit?.browserPanel(owning: responder, in: window)
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
    func closeDockPanel(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        _dockSplit?.closePanel(
            panelId,
            force: force,
            recordsHistory: recordsHistory
        ) ?? false
    }

    @discardableResult
    func closeDockPanelAndClearNotifications(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        guard closeDockPanel(
            panelId,
            force: force,
            recordsHistory: recordsHistory
        ) else {
            return false
        }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        return true
    }

    func openDockBrowserLinkInNewTab(panel: BrowserPanel, seed: BrowserNewTabNavigationSeed) -> Bool {
        guard !isRetiredFromOwningTabManager else { return false }
        guard let dock = _dockSplit, let paneId = dock.paneId(forPanelId: panel.id) else { return false }
        return dock.newSurface(
            kind: .browser,
            inPane: paneId,
            url: seed.url,
            initialRequest: seed.initialRequest,
            focus: true,
            preferredProfileID: panel.profileID,
            bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce,
            websiteDataStore: panel.explicitEphemeralWebsiteDataStoreForSibling
        ) != nil
    }

    static func openDockBrowserLinkInNewTabIfNeeded(panel: BrowserPanel, seed: BrowserNewTabNavigationSeed) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        if let target = app.browserActionTarget(for: panel),
           let dock = app.dock(resolving: target),
           dock.browserPanel(for: panel.id) === panel,
           let paneId = dock.paneId(forPanelId: panel.id) {
            return dock.newSurface(
                kind: .browser,
                inPane: paneId,
                url: seed.url,
                initialRequest: seed.initialRequest,
                focus: true,
                preferredProfileID: panel.profileID,
                bypassInsecureHTTPHostOnce: seed.bypassInsecureHTTPHostOnce,
                websiteDataStore: panel.explicitEphemeralWebsiteDataStoreForSibling
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
        guard let dock = focusedDockStoreForShortcut(
            action: .closeTab,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        guard let panelId = dock.focusedPanelId else { return true }
        if dock.closePanel(panelId, force: false) {
            notificationStore?.clearNotifications(
                forTabId: dock.workspaceId,
                surfaceId: panelId
            )
        }
        return true
    }
}

extension DockSplitStore {
    /// Applies the same browser-profile inheritance policy as a main-area
    /// workspace: an explicit profile wins, then the source browser's profile,
    /// then `BrowserPanel` falls back to the app's effective last-used profile.
    func resolvedNewBrowserProfileID(
        preferredProfileID: UUID?,
        sourcePanelId: UUID?
    ) -> UUID? {
        if let preferredProfileID,
           BrowserProfileStore.shared.profileDefinition(
               id: preferredProfileID
           ) != nil {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceBrowser = browserPanel(for: sourcePanelId),
           BrowserProfileStore.shared.profileDefinition(
               id: sourceBrowser.profileID
           ) != nil {
            return sourceBrowser.profileID
        }
        return nil
    }

    /// Builds a Dock browser panel with the workspace's remote-browser settings.
    func makeBrowserPanel(
        id: UUID = UUID(),
        url: URL?,
        initialRequest: URLRequest? = nil,
        preferredProfileID: UUID? = nil,
        renderInitialNavigation: Bool = true,
        bypassInsecureHTTPHostOnce: String? = nil,
        chromeVisibility: BrowserChromeVisibility = .visible,
        preloadInitialNavigationInBackground: Bool = false,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil
    ) -> BrowserPanel {
        let settings = currentRemoteBrowserSettings()
        let resolvedBypassRemoteProxy =
            bypassRemoteProxy ?? settings.bypassRemoteProxy
        let panel = BrowserPanel(
            id: id,
            workspaceId: workspaceId,
            profileID: preferredProfileID,
            initialURL: url,
            initialRequest: initialRequest,
            renderInitialNavigation: renderInitialNavigation,
            preloadInitialNavigationInBackground:
                preloadInitialNavigationInBackground,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            chromeVisibility: chromeVisibility,
            transparentBackground: transparentBackground,
            proxyEndpoint: settings.proxyEndpoint,
            bypassRemoteProxy: resolvedBypassRemoteProxy,
            isRemoteWorkspace: settings.isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: resolvedBypassRemoteProxy
                ? nil
                : settings.remoteWebsiteDataStoreIdentifier,
            websiteDataStore: websiteDataStore
        )
        panel.setRemoteWorkspaceStatus(settings.remoteStatus)
        configureBrowserPanel(panel)
        return panel
    }

    /// Rebinds host-owned actions whenever a live browser enters this Dock.
    /// A transferred panel may still carry closures owned by its old Workspace
    /// or Dock, so configuration is intentionally safe to repeat.
    func configureBrowserPanel(_ panel: BrowserPanel) {
        AppDelegate.shared?.auth?.browserAppSession.register(panel)
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
        panel.openAppLinkInBrowserSplit = { [weak self, weak panel] url in
            guard let self, let panel else { return false }
            return self.openAppLinkInBrowserSplit(url, from: panel)
        }
    }

    private func openAppLinkInBrowserSplit(
        _ destinationURL: URL,
        from sourcePanel: BrowserPanel
    ) -> Bool {
        guard isBrowserAvailable(), currentBrowserPanel(sourcePanel) else {
            return false
        }

        return appLinkHandoffCoordinator.start(
            sourcePanelID: sourcePanel.id,
            destinationURL: destinationURL,
            isCurrent: { [weak self, weak sourcePanel] in
                guard let self, let sourcePanel else { return false }
                return self.currentBrowserPanel(sourcePanel)
            },
            openNavigation: { [weak self, weak sourcePanel] navigation in
                guard let self, let sourcePanel else { return false }
                return self.openAppLinkNavigation(
                    navigation,
                    from: sourcePanel
                )
            },
            openRecovery: { [weak self, weak sourcePanel] in
                guard let self, let sourcePanel else { return false }
                return self.recoverAppLinkNavigation(
                    destinationURL,
                    from: sourcePanel
                )
            }
        )
    }

    private func openAppLinkNavigation(
        _ navigation: BrowserAppSessionNavigation,
        from sourcePanel: BrowserPanel
    ) -> Bool {
        guard currentBrowserPanel(sourcePanel),
              let sourcePane = paneId(forPanelId: sourcePanel.id) else {
            return false
        }
        return appLinkPlacementPolicy.openNavigation(
            navigation,
            openInPreferredPane: { request, websiteDataStore in
                guard let targetPane = BrowserRightSidePaneResolver()
                    .preferredPane(
                        from: sourcePane,
                        in: self.bonsplitController
                    ) else {
                    return false
                }
                return self.newSurface(
                    kind: .browser,
                    inPane: targetPane,
                    initialRequest: request,
                    focus: true,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore
                ) != nil
            },
            openHorizontalSplit: { request, websiteDataStore in
                self.newSplit(
                    kind: .browser,
                    orientation: .horizontal,
                    insertFirst: false,
                    sourcePanelId: sourcePanel.id,
                    initialRequest: request,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore,
                    focus: true
                ) != nil
            },
            openInSourcePane: { request, websiteDataStore in
                self.newSurface(
                    kind: .browser,
                    inPane: sourcePane,
                    initialRequest: request,
                    focus: true,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore
                ) != nil
            },
            isBrowserAvailable: { self.isBrowserAvailable() }
        )
    }

    private func currentBrowserPanel(_ sourcePanel: BrowserPanel) -> Bool {
        browserPanel(for: sourcePanel.id) === sourcePanel
    }

    private func recoverAppLinkNavigation(
        _ destinationURL: URL,
        from sourcePanel: BrowserPanel
    ) -> Bool {
        let sourcePane = currentBrowserPanel(sourcePanel)
            ? paneId(forPanelId: sourcePanel.id)
            : nil
        return appLinkPlacementPolicy.recover(
            destinationURL,
            openInPreferredPane: { url, websiteDataStore in
                guard let sourcePane,
                      let targetPane = BrowserRightSidePaneResolver()
                    .preferredPane(
                        from: sourcePane,
                        in: self.bonsplitController
                    ) else {
                    return false
                }
                return self.newSurface(
                    kind: .browser,
                    inPane: targetPane,
                    url: url,
                    focus: true,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore
                ) != nil
            },
            openHorizontalSplit: { url, websiteDataStore in
                guard sourcePane != nil else { return false }
                return self.newSplit(
                    kind: .browser,
                    orientation: .horizontal,
                    insertFirst: false,
                    sourcePanelId: sourcePanel.id,
                    url: url,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore,
                    focus: true
                ) != nil
            },
            openInSourcePane: { url, websiteDataStore in
                guard let sourcePane else { return false }
                return self.newSurface(
                    kind: .browser,
                    inPane: sourcePane,
                    url: url,
                    focus: true,
                    preferredProfileID: sourcePanel.profileID,
                    allowsExternalBrowserFallback: false,
                    websiteDataStore: websiteDataStore
                ) != nil
            },
            isBrowserAvailable: { self.isBrowserAvailable() }
        )
    }

    @discardableResult
    func closePanel(
        _ panelId: UUID,
        force: Bool = false,
        recordsHistory: Bool = true
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else { return false }
        if recordsHistory, !force {
            markDockCloseHistoryEligible(panelId: panelId)
        }
        if force { forceCloseDockTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId)
        if force && !closed { forceCloseDockTabIds.remove(tabId) }
        if !closed,
           !pendingCloseConfirmDockTabIds.contains(tabId) {
            discardDockClosedPanelHistory(tabId: tabId)
        }
        return closed
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
