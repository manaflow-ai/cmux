import AppKit
import CmuxCanvas
import CmuxPanes

/// Executes browser commands against an explicitly captured panel target.
@MainActor
struct BrowserActionDispatcher {
    let appDelegate: AppDelegate

    @discardableResult
    func perform(
        _ action: BrowserAction,
        on target: BrowserActionTarget
    ) -> Bool {
        guard let panel = appDelegate.browserPanel(resolving: target) else {
            return false
        }

        switch action {
        case .focus:
            return appDelegate.focusBrowserPanel(resolving: target)
        case .back:
            panel.goBack()
            return true
        case .forward:
            panel.goForward()
            return true
        case .reload:
            panel.reload()
            return true
        case .openInDefaultBrowser:
            return openInDefaultBrowser(panel)
        case .focusAddressBar:
            guard panel.chromeVisibility.allowsAddressBarFocus else {
                return true
            }
            return appDelegate.focusBrowserAddressBar(in: panel)
        case .toggleFocusMode(let reason):
            return panel.toggleBrowserFocusMode(
                reason: reason,
                focusWebView: true
            )
        case .toggleOmnibar:
            _ = panel.toggleOmnibarVisibility()
            return true
        case .toggleDeveloperTools:
            return panel.toggleDeveloperTools()
        case .showJavaScriptConsole:
            return panel.showDeveloperToolsConsole()
        case .toggleReactGrab:
            return toggleReactGrab(panel: panel, target: target)
        case .toggleDesignMode(let reason):
            Task { @MainActor [weak panel] in
                _ = await panel?.toggleDesignMode(reason: reason)
            }
            return true
        case .zoomIn:
            return panel.zoomIn()
        case .zoomOut:
            return panel.zoomOut()
        case .resetZoom:
            return panel.resetZoom()
        case .split(let direction):
            return splitBrowser(
                panel: panel,
                target: target,
                direction: direction
            )
        case .duplicateRight:
            return duplicateBrowser(target: target)
        case .moveToNewWorkspace:
            return moveBrowserToNewWorkspace(target: target)
        case .startFind:
            panel.startFind()
            return panel.searchState != nil
        case .findNext:
            panel.findNext()
            return true
        case .findPrevious:
            panel.findPrevious()
            return true
        case .hideFind:
            panel.hideFind()
            return true
        }
    }

    private func openInDefaultBrowser(_ panel: BrowserPanel) -> Bool {
        guard let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func toggleReactGrab(
        panel: BrowserPanel,
        target: BrowserActionTarget
    ) -> Bool {
        switch target.host {
        case .workspace(let workspaceId):
            guard let workspace = appDelegate.workspace(resolving: target),
                  let manager = appDelegate.tabManagerFor(tabId: workspaceId) else {
                return false
            }
            return manager.toggleReactGrab(
                in: workspace,
                browserSurfaceId: panel.id,
                returnTerminalSurfaceId: nil
            ) != nil
        case .workspaceDock, .windowDock:
            return appDelegate.dock(resolving: target)?
                .toggleDockReactGrab(targeting: panel.id) ?? false
        }
    }

    private func splitBrowser(
        panel: BrowserPanel,
        target: BrowserActionTarget,
        direction: SplitDirection
    ) -> Bool {
        switch target.host {
        case .workspace:
            guard let workspace = appDelegate.workspace(resolving: target) else {
                return false
            }
            if workspace.layoutMode == .canvas {
                guard let panelId = workspace.openNewCanvasPane(
                    type: .browser,
                    focus: true,
                    direction: direction.canvasDirection
                ) else {
                    return false
                }
                _ = appDelegate.focusBrowserAddressBar(panelId: panelId)
                return true
            }
            workspace.clearSplitZoom()
            guard let splitPanel = workspace.newBrowserSplit(
                from: panel.id,
                orientation: direction.orientation,
                insertFirst: direction.insertFirst,
                preferredProfileID: panel.profileID,
                focus: true,
                websiteDataStore:
                    panel.explicitEphemeralWebsiteDataStoreForSibling
            ) else {
                return false
            }
            _ = appDelegate.focusBrowserAddressBar(in: splitPanel)
            return true
        case .workspaceDock, .windowDock:
            guard let dock = appDelegate.dock(resolving: target),
                  let splitPanelId = dock.newSplit(
                kind: .browser,
                orientation: direction.orientation,
                insertFirst: direction.insertFirst,
                sourcePanelId: panel.id,
                preferredProfileID: panel.profileID,
                websiteDataStore:
                    panel.explicitEphemeralWebsiteDataStoreForSibling,
                focus: false
            ),
            let splitPanel = dock.browserPanel(for: splitPanelId) else {
                return false
            }
            dock.focusPanelFromDockInteraction(splitPanelId, window: nil)
            _ = appDelegate.focusBrowserAddressBar(in: splitPanel)
            return true
        }
    }

    private func duplicateBrowser(
        target: BrowserActionTarget
    ) -> Bool {
        switch target.host {
        case .workspace:
            return appDelegate.workspace(resolving: target)?
                .duplicateBrowserToRight(panelId: target.panelId) != nil
        case .workspaceDock, .windowDock:
            return appDelegate.dock(resolving: target)?
                .duplicateBrowserToRight(panelId: target.panelId) != nil
        }
    }

    func canMoveBrowserToNewWorkspace(
        target: BrowserActionTarget
    ) -> Bool {
        switch target.host {
        case .workspace:
            guard let workspace = appDelegate.workspace(resolving: target),
                  workspace.browserPanel(for: target.panelId) != nil else {
                return false
            }
            return workspace.panels.count > 1
        case .workspaceDock, .windowDock:
            guard let dock = appDelegate.dock(resolving: target),
                  dock.browserPanel(for: target.panelId) != nil else {
                return false
            }
            return dock.panels.count > 1
        }
    }

    private func moveBrowserToNewWorkspace(
        target: BrowserActionTarget
    ) -> Bool {
        guard canMoveBrowserToNewWorkspace(target: target) else {
            return false
        }
        switch target.host {
        case .workspace:
            return appDelegate.moveSurfaceToNewWorkspace(
                panelId: target.panelId,
                focus: true,
                focusWindow: false
            ) != nil
        case .workspaceDock, .windowDock:
            guard let dock = appDelegate.dock(resolving: target) else {
                return false
            }
            return appDelegate.moveDockSurfaceToNewWorkspace(
                sourceDock: dock,
                panelId: target.panelId,
                focus: true,
                focusWindow: false
            )
        }
    }
}
