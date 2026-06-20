import AppKit
import CmuxCore

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
        return panel
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
