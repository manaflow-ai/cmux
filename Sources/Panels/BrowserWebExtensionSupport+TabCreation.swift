import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor
extension BrowserWebExtensionSupport {
    func openBrowserTab(
        url: URL?,
        initialRequest: URLRequest? = nil,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserWebExtensionTabAdapter? {
        if let sourcePanel = implicitTabCreationSourcePanel() {
            if let panel = openWorkspaceBrowserTab(
                sourcePanel: sourcePanel,
                url: url,
                initialRequest: initialRequest,
                shouldActivate: shouldActivate,
                webViewConfiguration: webViewConfiguration
            ) {
                return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
            }
            if let panel = openDockBrowserTab(
                sourcePanel: sourcePanel,
                url: url,
                initialRequest: initialRequest,
                shouldActivate: shouldActivate,
                webViewConfiguration: webViewConfiguration
            ) {
                return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
            }
        }

        guard let tabManager = AppDelegate.shared?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) else { return nil }
        return openBrowserTab(
            in: tabManager,
            url: url,
            initialRequest: initialRequest,
            shouldActivate: shouldActivate,
            webViewConfiguration: webViewConfiguration
        )
    }

    func implicitTabCreationSourcePanel() -> BrowserPanel? {
        guard let sourcePanel = activeTabAdapter?.panel else { return nil }
        guard let keyWindow = NSApp.keyWindow,
              AppDelegate.shared?.isMainTerminalWindow(keyWindow) == true else {
            return sourcePanel
        }
        return windowAdapter(for: sourcePanel.id)?.hostWindow === keyWindow ? sourcePanel : nil
    }

    func openBrowserTab(
        in tabManager: TabManager,
        url: URL?,
        initialRequest: URLRequest? = nil,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserWebExtensionTabAdapter? {
        guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
              let paneID = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return nil }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        guard let panel = workspace.newBrowserSurface(
            inPane: paneID,
            url: url,
            initialRequest: initialRequest,
            focus: shouldActivate,
            preferredProfileID: workspace.preferredBrowserProfileID,
            creationPolicy: .extensionRequested,
            webViewConfiguration: webViewConfiguration
        ) else { return nil }
        return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
    }

    private func openWorkspaceBrowserTab(
        sourcePanel: BrowserPanel,
        url: URL?,
        initialRequest: URLRequest?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserPanel? {
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: sourcePanel.id,
            preferredWorkspaceId: sourcePanel.workspaceId
        )?.workspace,
            let paneId = workspace.paneId(forPanelId: sourcePanel.id) else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            initialRequest: initialRequest,
            focus: shouldActivate,
            preferredProfileID: sourcePanel.profileID,
            creationPolicy: .extensionRequested,
            webViewConfiguration: webViewConfiguration
        )
    }

    private func openDockBrowserTab(
        sourcePanel: BrowserPanel,
        url: URL?,
        initialRequest: URLRequest?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserPanel? {
        guard let dock = dockContainingPanel(sourcePanel.id),
              let paneId = dock.paneId(forPanelId: sourcePanel.id),
              let panelID = dock.newSurface(
                  kind: .browser,
                  inPane: paneId,
                  url: url,
                  initialRequest: initialRequest,
                  focus: shouldActivate,
                  preferredProfileID: sourcePanel.profileID,
                  creationPolicy: .extensionRequested,
                  webViewConfiguration: webViewConfiguration
              ) else { return nil }
        return dock.browserPanel(for: panelID)
    }

    private func tabAdapterForOpenedPanel(
        _ panel: BrowserPanel,
        shouldActivate: Bool
    ) -> BrowserWebExtensionTabAdapter? {
        if shouldActivate {
            noteActivated(panelID: panel.id)
        }
        return tabAdapter(for: panel.id)
    }

    func focusOwningCmuxTab(panelID: UUID, workspaceId: UUID) -> Bool {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: workspaceId
        )?.workspace {
            workspace.focusPanel(panelID)
            return true
        }
        guard let dock = dockContainingPanel(panelID) else { return false }
        dock.focusPanel(panelID)
        return true
    }

    func dockContainingPanel(_ panelID: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first { $0.containsPanel(panelID) }
    }
}
