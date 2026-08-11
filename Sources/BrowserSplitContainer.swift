import Bonsplit
import CmuxBrowser
import CmuxPanes
import Foundation

/// Adapts the main workspace and Dock split trees to one browser-placement path.
@MainActor
enum BrowserSplitContainer {
    case workspace(Workspace)
    case dock(DockSplitStore)

    /// The result of placing a browser to the right of a source surface.
    struct Placement {
        let panel: BrowserPanel
        let createdSplit: Bool
    }

    /// Browser creation options shared by the main workspace and Dock hosts.
    struct Request {
        let url: URL?
        let focus: Bool
        let preferredProfileID: UUID?
        let chromeVisibility: BrowserChromeVisibility
        let transparentBackground: Bool
        let bypassRemoteProxy: Bool
    }

    var host: PanelHost {
        switch self {
        case .workspace(let workspace):
            return .workspace(workspace.id)
        case .dock(let dock):
            switch dock.scope {
            case .workspace:
                return .workspaceDock(dock.workspaceId)
            case .global:
                return .windowDock(dock.workspaceId)
            }
        }
    }

    var ownerID: UUID {
        host.ownerID
    }

    var isRemoteWorkspace: Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.isRemoteWorkspace
        case .dock(let dock):
            return dock.currentRemoteBrowserSettings().isRemoteWorkspace
        }
    }

    /// Resolves an explicit surface or pane selection, then falls back to focus.
    func sourcePanelID(
        requestedSurfaceID: UUID?,
        requestedPaneID: UUID?
    ) -> UUID? {
        if let requestedSurfaceID {
            return containsPanel(requestedSurfaceID)
                ? requestedSurfaceID
                : nil
        }
        if let requestedPaneID {
            return selectedPanelID(inPane: requestedPaneID)
        }
        switch self {
        case .workspace(let workspace):
            return workspace.focusedPanelId
        case .dock(let dock):
            return dock.focusedPanelId
        }
    }

    func containsPanel(_ panelID: UUID) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.panels[panelID] != nil
        case .dock(let dock):
            return dock.containsPanel(panelID)
        }
    }

    func paneID(forPanelID panelID: UUID) -> PaneID? {
        switch self {
        case .workspace(let workspace):
            return workspace.paneId(forPanelId: panelID)
        case .dock(let dock):
            return dock.paneId(forPanelId: panelID)
        }
    }

    /// Reuses the nearest pane on the right or creates a horizontal split.
    func openBrowserToRight(
        of sourcePanelID: UUID,
        request: Request
    ) -> Placement? {
        guard containsPanel(sourcePanelID),
              let sourcePane = paneID(forPanelID: sourcePanelID) else {
            return nil
        }

        if let targetPane = preferredRightSidePane(from: sourcePane) {
            return createBrowserSurface(
                in: targetPane,
                request: request
            ).map {
                Placement(panel: $0, createdSplit: false)
            }
        }

        return createBrowserSplit(
            from: sourcePanelID,
            request: request
        ).map {
            Placement(panel: $0, createdSplit: true)
        }
    }

    private func selectedPanelID(inPane requestedPaneID: UUID) -> UUID? {
        switch self {
        case .workspace(let workspace):
            guard let pane = workspace.bonsplitController.allPaneIds.first(
                where: { $0.id == requestedPaneID }
            ), let tabID = workspace.bonsplitController.selectedTab(
                inPane: pane
            )?.id else {
                return nil
            }
            return workspace.panelIdFromSurfaceId(tabID)
        case .dock(let dock):
            guard let pane = dock.bonsplitController.allPaneIds.first(
                where: { $0.id == requestedPaneID }
            ), let tabID = dock.bonsplitController.selectedTab(
                inPane: pane
            )?.id else {
                return nil
            }
            return dock.panel(for: tabID)?.id
        }
    }

    private func preferredRightSidePane(from sourcePane: PaneID) -> PaneID? {
        switch self {
        case .workspace(let workspace):
            return BrowserRightSidePaneResolver().preferredPane(
                from: sourcePane,
                in: workspace.bonsplitController
            )
        case .dock(let dock):
            return BrowserRightSidePaneResolver().preferredPane(
                from: sourcePane,
                in: dock.bonsplitController
            )
        }
    }

    private func createBrowserSurface(
        in paneID: PaneID,
        request: Request
    ) -> BrowserPanel? {
        switch self {
        case .workspace(let workspace):
            return workspace.newBrowserSurface(
                inPane: paneID,
                url: request.url,
                focus: request.focus,
                selectWhenNotFocused: true,
                preferredProfileID: request.preferredProfileID,
                creationPolicy: .automationPreload,
                chromeVisibility: request.chromeVisibility,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy
            )
        case .dock(let dock):
            guard let panelID = dock.newSurface(
                kind: .browser,
                inPane: paneID,
                url: request.url,
                focus: request.focus,
                preferredProfileID: request.preferredProfileID,
                chromeVisibility: request.chromeVisibility,
                preloadInitialNavigationInBackground: true,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy
            ) else {
                return nil
            }
            return dock.browserPanel(for: panelID)
        }
    }

    private func createBrowserSplit(
        from sourcePanelID: UUID,
        request: Request
    ) -> BrowserPanel? {
        switch self {
        case .workspace(let workspace):
            return workspace.newBrowserSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                url: request.url,
                preferredProfileID: request.preferredProfileID,
                focus: request.focus,
                creationPolicy: .automationPreload,
                chromeVisibility: request.chromeVisibility,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy
            )
        case .dock(let dock):
            guard let panelID = dock.newSplit(
                kind: .browser,
                orientation: .horizontal,
                insertFirst: false,
                sourcePanelId: sourcePanelID,
                url: request.url,
                preferredProfileID: request.preferredProfileID,
                chromeVisibility: request.chromeVisibility,
                preloadInitialNavigationInBackground: true,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy,
                focus: request.focus
            ) else {
                return nil
            }
            return dock.browserPanel(for: panelID)
        }
    }
}
