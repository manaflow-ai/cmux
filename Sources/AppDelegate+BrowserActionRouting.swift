import AppKit
import Bonsplit
import WebKit

extension AppDelegate {
    /// Returns the owner installed by a browser panel on its navigation delegate.
    /// This direct link is the fast path for responder routing; the collection
    /// lookup below remains only as a recovery path while a web view is being
    /// rebound or its delegate is temporarily unavailable.
    func directBrowserPanelOwner(of webView: WKWebView) -> BrowserPanel? {
        guard let navigationDelegate = webView.navigationDelegate as? BrowserNavigationDelegate,
              let panel = navigationDelegate.owner,
              panel.webView === webView else {
            return nil
        }
        return panel
    }

    /// Whether a ``CmuxWebView`` belongs to a cmux browser surface.
    ///
    /// The navigation-delegate owner and portal context are both direct,
    /// bounded ownership signals. They keep keyboard routing off the global
    /// Dock/workspace scan used only for recovery and test setup.
    func isBrowserPanelWebView(_ webView: CmuxWebView) -> Bool {
        directBrowserPanelOwner(of: webView) != nil
            || BrowserWindowPortalRegistry.paneDropContext(for: webView) != nil
            || webView.isBrowserPopupWebView
    }

    /// Resolves a browser panel by its globally unique panel identifier.
    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        if let dock = DockSplitStore.liveStores.first(where: {
            $0.containsPanel(panelId)
        }),
           let panel = dock.browserPanel(for: panelId) {
            return panel
        }
        return workspaceContainingPanel(panelId: panelId)?
            .workspace.browserPanel(for: panelId)
    }

    /// Resolves the browser model that owns an AppKit web view.
    func browserPanel(owning webView: WKWebView) -> BrowserPanel? {
        if let panel = directBrowserPanelOwner(of: webView) {
            return panel
        }

        if let context = BrowserWindowPortalRegistry.paneDropContext(
            for: webView
        ),
        let panel = browserPanel(for: context.panelId),
        panel.webView === webView {
            return panel
        }

        for dock in DockSplitStore.liveStores {
            if let panel = dock.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView }) {
                return panel
            }
        }
        for manager in browserCandidateTabManagers() {
            for workspace in manager.tabs {
                if let panel = workspace.panels.values
                    .compactMap({ $0 as? BrowserPanel })
                    .first(where: { $0.webView === webView }) {
                    return panel
                }
            }
        }
        return nil
    }

    /// Captures the focused browser together with its owning split container.
    func focusedBrowserActionTarget(
        preferredWindow: NSWindow?
    ) -> BrowserActionTarget? {
        let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let panel = focusedBrowserPanelForAction(in: window) else {
            return nil
        }
        return browserActionTarget(for: panel)
    }

    func browserActionTarget(
        for panel: BrowserPanel
    ) -> BrowserActionTarget? {
        if let dock = DockSplitStore.liveStores.first(where: {
            $0.browserPanel(for: panel.id) === panel
        }) {
            return BrowserActionTarget(
                host: panelHost(for: dock),
                panelId: panel.id
            )
        }

        guard let manager = tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: {
                  $0.id == panel.workspaceId
              }),
              workspace.browserPanel(for: panel.id) === panel else {
            return nil
        }
        return BrowserActionTarget(
            host: .workspace(workspace.id),
            panelId: panel.id
        )
    }

    func browserPanel(
        resolving target: BrowserActionTarget
    ) -> BrowserPanel? {
        switch target.host {
        case .workspace(let workspaceId):
            guard let manager = tabManagerFor(tabId: workspaceId),
                  let workspace = manager.tabs.first(where: {
                      $0.id == workspaceId
                  }) else {
                return nil
            }
            return workspace.browserPanel(for: target.panelId)
        case .workspaceDock, .windowDock:
            return dock(resolving: target)?.browserPanel(
                for: target.panelId
            )
        }
    }

    /// Performs the shared foreground-selection transaction for a browser.
    /// Explicit focus actions activate the owning window, select the owning
    /// workspace when there is one, and reveal a window Dock before selecting
    /// its panel. Non-focus browser actions deliberately bypass this path.
    @discardableResult
    func focusBrowserPanel(
        resolving target: BrowserActionTarget
    ) -> Bool {
        guard let panel = browserPanel(resolving: target) else {
            return false
        }

        switch target.host {
        case .workspace(let workspaceID):
            guard let manager = tabManagerFor(tabId: workspaceID),
                  let workspace = manager.tabs.first(where: {
                      $0.id == workspaceID &&
                          $0.browserPanel(for: panel.id) === panel
                  }) else {
                return false
            }
            activateBrowserHostWindow(for: manager)
            manager.focusTab(workspace.id, surfaceId: panel.id)
            return true

        case .workspaceDock(let workspaceID):
            guard let dock = dock(resolving: target),
                  dock.browserPanel(for: panel.id) === panel,
                  let manager = tabManagerFor(tabId: workspaceID),
                  let workspace = manager.tabs.first(where: {
                      $0.id == workspaceID
                  }) else {
                return false
            }
            activateBrowserHostWindow(for: manager)
            manager.focusTab(workspace.id)
            dock.focusPanel(panel.id)
            return true

        case .windowDock(let windowID):
            guard let dock = dock(resolving: target),
                  dock.browserPanel(for: panel.id) === panel else {
                return false
            }
            let preferredWindow = mainWindow(for: windowID)
            if let manager = tabManagerFor(windowId: windowID) {
                activateBrowserHostWindow(for: manager)
            } else {
                _ = focusMainWindow(windowId: windowID)
            }
            _ = focusRightSidebarInActiveMainWindow(
                mode: .dock,
                focusFirstItem: false,
                preferredWindow: preferredWindow
            )
            dock.focusPanel(panel.id)
            return true
        }
    }

    func workspace(
        resolving target: BrowserActionTarget
    ) -> Workspace? {
        guard case .workspace(let workspaceId) = target.host,
              let manager = tabManagerFor(tabId: workspaceId) else {
            return nil
        }
        return manager.tabs.first(where: { $0.id == workspaceId })
    }

    /// Opens browser file-drop fallbacks in the workspace split tree associated
    /// with the browser host. Dock trees intentionally contain only terminal
    /// and browser panels, so their previews are placed beside the currently
    /// focused main-area pane instead of being rejected or misrouted.
    @discardableResult
    func openFilePreviews(
        _ urls: [URL],
        relativeTo target: BrowserActionTarget,
        zone: DropZone
    ) -> Bool {
        guard let placement = browserFilePreviewPlacement(
            resolving: target
        ) else {
            return false
        }
        return placement.workspace.handleExternalFileDrop(
            BonsplitController.ExternalFileDropRequest(
                urls: urls,
                destination: PaneDropRouting.destination(
                    targetPane: placement.paneID,
                    zone: zone
                )
            )
        )
    }

    func panelHost(for dock: DockSplitStore) -> PanelHost {
        switch dock.scope {
        case .workspace:
            return .workspaceDock(dock.workspaceId)
        case .global:
            return .windowDock(dock.workspaceId)
        }
    }

    func dock(
        resolving target: BrowserActionTarget
    ) -> DockSplitStore? {
        let scope: DockScope
        let ownerId: UUID
        switch target.host {
        case .workspace:
            return nil
        case .workspaceDock(let workspaceId):
            scope = .workspace
            ownerId = workspaceId
        case .windowDock(let windowId):
            scope = .global
            ownerId = windowId
        }
        return DockSplitStore.liveStores.first {
            $0.scope == scope && $0.workspaceId == ownerId
        }
    }

    /// Returns the window-local workspace manager that a browser should use
    /// for cross-tab actions such as omnibar suggestions and tab switching.
    func browserReferenceTabManager(
        for panel: BrowserPanel
    ) -> TabManager? {
        if let dock = DockSplitStore.liveStores.first(where: {
            $0.browserPanel(for: panel.id) === panel
        }) {
            return dockReferenceTabManager(for: dock)
        }
        return tabManagerFor(tabId: panel.workspaceId)
    }

    private func browserCandidateTabManagers() -> [TabManager] {
        let candidates = [tabManager]
            + mainWindowContexts.values.map { Optional($0.tabManager) }
        var seen = Set<ObjectIdentifier>()
        return candidates.compactMap { candidate in
            guard let candidate,
                  seen.insert(ObjectIdentifier(candidate)).inserted else {
                return nil
            }
            return candidate
        }
    }

    private func browserFilePreviewPlacement(
        resolving target: BrowserActionTarget
    ) -> (workspace: Workspace, paneID: PaneID)? {
        let workspace: Workspace?
        let preferredPanelID: UUID?
        switch target.host {
        case .workspace:
            workspace = self.workspace(resolving: target)
            preferredPanelID = target.panelId
        case .workspaceDock(let workspaceID):
            workspace = workspaceFor(tabId: workspaceID)
            preferredPanelID = workspace?.focusedPanelId
        case .windowDock(let windowID):
            workspace = tabManagerFor(windowId: windowID)?.selectedWorkspace
            preferredPanelID = workspace?.focusedPanelId
        }
        guard let workspace else { return nil }
        let paneID = preferredPanelID.flatMap {
            workspace.paneId(forPanelId: $0)
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let paneID else { return nil }
        return (workspace, paneID)
    }

    private func activateBrowserHostWindow(for manager: TabManager) {
        guard let windowID = windowId(for: manager) else { return }
        _ = focusMainWindow(windowId: windowID)
        guard let window = mainWindow(for: windowID) else { return }
        _ = synchronizeActiveMainWindowContext(preferredWindow: window)
    }
}
