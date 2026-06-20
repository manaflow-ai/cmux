import AppKit

extension Workspace {
    func dockBrowserPanel(for panelId: UUID) -> BrowserPanel? {
        _dockSplit?.browserPanel(for: panelId)
    }

    func dockBrowserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        _dockSplit?.browserPanel(owning: responder, in: window)
    }

    func containsDockPane(_ paneId: UUID) -> Bool {
        _dockSplit?.containsPane(paneId) ?? false
    }

    func openDockBrowserLinkInNewTab(panel: BrowserPanel, seed: BrowserNewTabNavigationSeed) -> Bool {
        guard let dock = _dockSplit, let paneId = dock.paneId(forPanelId: panel.id) else { return false }
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
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }) else { return false }
        return workspace.openDockBrowserLinkInNewTab(panel: panel, seed: seed)
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
        return BrowserPanel(
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
    }
}
