import CmuxNextBridge
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextLayout
import Foundation

extension ChatColumnPlacement {
    /// What a person's new tab from `controller`'s pane becomes.
    @MainActor static func resolve(from controller: PaneController, services: AppServices) -> ChatColumnPlacement {
        guard let content = controller.workspace,
              content.daemon.supports(DaemonCapability.dockColumnRole.rawValue),
              let screen = content.layoutModel.screen(containing: controller.layoutPaneID) else { return .here }
        let columns = columns(of: screen, containing: controller.layoutPaneID)
        // A zoomed screen maps to its zoomed pane alone (LayoutMapping).
        let zoomed = content.workspace.screens.contains { screen in
            screen.zoomedPane != nil && screen.panes.contains { $0 === controller.pane }
        }
        return resolve(from: controller.layoutPaneID, columns: columns, recent: content.recentPanes, zoomed: zoomed) { column in
            guard column.root.panes.count == 1, let tabs = content.panes[column.root.panes[0]]?.pane.tabs,
                  tabs.count == 1 else { return false }
            return isChat(tabs[0], services: services)
        }
    }

    /// Whether `tab` is an agent chat. The New Tab page is an agent tab too, but not a chat.
    /// Reads `tab` itself: finding it again by id walks every workspace's tabs, once per
    /// tab of a pane whose tab bar is drawn (cx-6so.21).
    @MainActor static func isChat(_ tab: TabModel, services: AppServices) -> Bool {
        tab.agentSession != nil && !services.agentTabs.isNewTabPage(tab.id)
    }

    /// Where a person's new tab from `controller`'s pane opens: the pane
    /// to open it in (`controller` itself, or the strip pane, focused), or
    /// nil when it is already open. A lone chat moves into a new left dock
    /// with the agent chat role, leaving `respawn` in its pane, in one daemon
    /// commit, whether or not it shows its tab bar (cx-v4dmy: every chat shows
    /// it by default). Without `respawn` (a New Tab page, which is not a daemon
    /// tab) it stays in `controller`.
    @MainActor static func route(from controller: PaneController, respawn: SplitRespawn?,
                                 services: AppServices) -> PaneController? {
        guard let content = controller.workspace else { return controller }
        let placement = resolve(from: controller, services: services)
        switch placement {
        case .here:
            return controller
        case .tab(let target):
            guard let strip = content.panes[target] else { return controller }
            PaneHandlers.focus(target, in: content)
            return strip
        case .dockChat:
            guard let respawn, controller.daemon.supports(DaemonCapability.tabColumnRespawn.rawValue),
                  let chat = controller.pane.tabs.first else { return controller }
            // The new tab left in the pane takes focus, not the docked chat. The chat stays where it
            // shows; only the pane with the new tab comes in, from the right (as AgentBesidePlacement).
            let pane = controller.layoutPaneID
            content.layoutModel.handOffContent(of: pane) { done in
                TabMoves.toNewDockColumn(chat, anchor: controller.pane, edge: .left, role: .agentChat,
                                         respawn: respawn, services: services) { [weak content, weak controller] moved in
                    done(moved)
                    if moved, let content { PaneHandlers.focus(pane, in: content) }
                    // A hidden tab bar was the chat's choice: the tab left in the pane shows its tab bar again.
                    if moved, let controller, services.paneTabBars.choice(for: controller.paneKey) == false {
                        services.paneTabBars.set(nil, for: controller.paneKey)
                        controller.apply(controller.snapshot())
                    }
                }
            }
            return nil
        case .besideDock:
            openBesideDock(controller, respawn: respawn, services: services)
            return nil
        }
    }

    /// A person's new tab from Home's pinned dock alone (`pinned-dock-alone-v1`): a new column
    /// right of the dock holds it. A terminal is a new column with its shell, spawned with the
    /// tab's options (cwd, keep); a web page opens the way Home's links do (`workspace.open_url`,
    /// which makes the column right of a lone dock); the New Tab page is a split to the right,
    /// which the daemon makes a column beside the dock; any other address is a browser tab aimed
    /// at the dock, which the daemon makes in a new column right of it.
    @MainActor static func openBesideDock(_ controller: PaneController, respawn: SplitRespawn?, services: AppServices) {
        switch respawn {
        case .terminal(let spawn)?:
            controller.workspace?.newColumn(after: controller.layoutPaneID, options: spawn)
        case .browser(let url, _, _)? where URL(string: url).map(isWebPage) == true:
            let daemon = controller.daemon
            services.registry.track(Task { @MainActor in
                _ = await daemon.request("workspace.open_url") { try await WorkspaceOpenURLClient($0).openOnHome(url) }
                return nil
            })
        case .browser(let url, let engine, let profileID)? where !isNewTabAddress(url, services: services):
            // A browser tab aimed at the lone dock opens in a new column right of it (the daemon's
            // reroute, or PaneBrowserTabOpener's move while the dock takes tabs).
            controller.newBrowserTab(url: URL(string: url), engine: engine.rawValue, profile: profileID)
        case .browser?, nil:
            NewTabPage.split(controller, edge: .right)
        }
    }

    /// Whether `url` is a New Tab page address (the setting's page or an engine's own).
    @MainActor private static func isNewTabAddress(_ url: String, services: AppServices) -> Bool {
        [BrowserEngineChoice(engine: .cef), BrowserEngineChoice(engine: .webkit)].contains { services.newTabAddress(for: $0) == url }
    }

    private static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
