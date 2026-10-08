import AppKit
import CmuxNextAgentCursorVisibility
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextLayout
import CmuxNextSidebar
import CmuxNextTabs

/// Reads the live models into the agent cursor's visibility snapshot for
/// one target tab (`AgentCursorVisibilityResolver` decides). Only the facts
/// that target needs: its pane in the window that shows its workspace, its
/// sidebar row in a window that only lists it. Every rect is in the
/// window's content-view coordinates, flipped (origin top-left, y down):
/// the space of the window-level cursor host (`AgentCursorContentSpace`).
struct AgentCursorSnapshotBuilder {
    weak var services: AppServices?

    func snapshot(forTarget id: String) -> AgentCursorVisibilitySnapshot {
        guard let services else { return AgentCursorVisibilitySnapshot(tab: nil, windows: []) }
        let location = locate(id, services)
        return AgentCursorVisibilitySnapshot(tab: location, windows: orderedControllers(services).map {
            window($0, target: id, location: location, services)
        })
    }

    // MARK: Target

    /// The workspace and pane of tab `id` (daemon tabs, then this session's local browser tabs).
    private func locate(_ id: String, _ services: AppServices) -> AgentCursorVisibilitySnapshot.TabLocation? {
        if let (_, pane) = services.locateTab(id), let workspace = workspaceID(containingPane: pane.id, services) {
            return .init(workspace: workspace, pane: pane.id)
        }
        for controller in services.windows.controllers {
            for (pane, tabs) in controller.state.localBrowserTabs where tabs.contains(where: { $0.id == id }) {
                if let workspace = workspaceID(containingPane: pane, services) { return .init(workspace: workspace, pane: pane) }
            }
        }
        return nil
    }

    private func workspaceID(containingPane pane: String, _ services: AppServices) -> String? {
        services.machines.allWorkspaces.first { workspace, _ in
            workspace.screens.contains { $0.panes.contains { $0.id == pane } }
        }?.0.id
    }

    // MARK: Windows

    /// Windows front to back (`NSApp.orderedWindows`); unordered ones last.
    private func orderedControllers(_ services: AppServices) -> [WindowController] {
        let order = NSApp.orderedWindows
        func rank(_ controller: WindowController) -> Int {
            order.firstIndex { $0 === controller.window } ?? Int.max
        }
        return services.windows.controllers.sorted { rank($0) < rank($1) }
    }

    private func window(_ controller: WindowController, target: String,
                        location: AgentCursorVisibilitySnapshot.TabLocation?, _ services: AppServices) -> AgentCursorVisibilitySnapshot.Window {
        let window = controller.window
        let content = controller.content
        let space = window?.contentView.map(AgentCursorContentSpace.init)
        // The Home page draws the home workspace's chief conversation: that workspace is on screen.
        let homePage = controller.shownTopPage == .home ? controller.topPages.views[.home] : nil
        let shown = content?.workspace.id ?? homePage.flatMap { _ in services.home.homeWorkspace?.id }
        var rows: [String: AgentCursorRect] = [:]
        var panes: [AgentCursorVisibilitySnapshot.Pane] = []
        if let location, let space {
            if shown == location.workspace {
                if let content, let pane = pane(location.pane, target: target, content: content, space: space) {
                    panes = [pane]
                } else if let homePage, homePage.window != nil {
                    panes = [Self.page(location.pane, target: target, view: homePage, space: space)]
                }
            } else {
                let sidebar = controller.sidebar.container.sidebarView
                // The home workspace has no list row while the Home item shows: that item is its row.
                let isHome = services.home.homeWorkspace?.id == location.workspace
                if let row = SidebarRowAnchor.workspaceRow(SidebarWorkspaceID(location.workspace), in: sidebar)
                    ?? (isHome ? SidebarRowAnchor.layoutItem(SidebarLayoutDocument.homeRef, in: sidebar) : nil) {
                    rows[location.workspace] = AgentCursorRect(space.rect(row, from: sidebar))
                }
            }
        }
        return AgentCursorVisibilitySnapshot.Window(
            id: controller.state.id,
            screen: window?.screen?.localizedName,
            minimized: window?.isMiniaturized ?? true,
            onActiveSpace: window?.isOnActiveSpace ?? false,
            overlay: AgentCursorRect(space?.bounds ?? .zero),
            shownWorkspace: shown,
            listedWorkspaces: services.windows.registry.members(of: controller.state.id),
            sidebarHidden: controller.state.sidebarHidden,
            sidebarRows: rows,
            panes: panes
        )
    }

    // MARK: Pane

    /// A top page that draws `pane`'s content: the page's bounds are the
    /// pane's frame and clip; it has no strip.
    private static func page(_ key: String, target: String, view: NSView,
                             space: AgentCursorContentSpace) -> AgentCursorVisibilitySnapshot.Pane {
        let frame = AgentCursorRect(space.rect(view.bounds, from: view))
        return AgentCursorVisibilitySnapshot.Pane(id: key, frame: frame, clip: frame, selectedTab: target, strip: nil, chips: [:], page: nil)
    }

    private func pane(_ key: String, target: String, content: WorkspaceContentController,
                      space: AgentCursorContentSpace) -> AgentCursorVisibilitySnapshot.Pane? {
        let root: LayoutRootView = content.layoutView
        guard let controller = content.paneController(key: key) else { return nil }
        let visibility = root.visibility(of: controller.layoutPaneID)
        let strip = controller.view.stripView
        let selected = controller.stripModel.selectedID?.rawValue
        var chips: [String: AgentCursorRect] = [:]
        if let chip = TabChipAnchor.rect(of: StripTabID(target), in: strip) {
            chips[target] = AgentCursorRect(space.rect(chip, from: strip))
        }
        var page: AgentCursorVisibilitySnapshot.Page?
        if selected == target, controller.currentTabKey == target, case let .browser(entry)? = controller.currentContent,
           entry.chrome.window != nil {
            page = .init(viewport: AgentCursorRect(space.rect(entry.chrome.pageViewportRect, from: entry.chrome)),
                         zoom: entry.tab.state.zoom)
        }
        return AgentCursorVisibilitySnapshot.Pane(
            id: key,
            frame: visibility.map { AgentCursorRect(space.rect($0.frame, from: root)) },
            clip: visibility.map { AgentCursorRect(space.rect($0.clip, from: root)) },
            selectedTab: selected,
            strip: strip.window == nil ? nil : AgentCursorRect(space.rect(strip.bounds, from: strip)),
            chips: chips,
            page: page
        )
    }
}
