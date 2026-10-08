import CmuxNextControl
import CmuxNextDaemon

/// Maps the daemon mirror into the control socket's value topology. Pure;
/// the publisher calls it inside Observation tracking so every property it
/// reads schedules the next publish when it changes.
extension ControlTabInfo {
    func withTerminalResource(_ id: String?) -> ControlTabInfo {
        var info = self
        info.terminalResourceID = id
        return info
    }
}

/// What the app knows of page tabs that the daemon tree does not
/// (bd cx-5xsi): a pane's app-only page tabs and each page's title.
struct ControlPageFacts {
    var appOnlyTabs: (PaneModel) -> [ControlPageTabInfo] = { _ in [] }
    /// The title of internal page `id` (`app-store`), nil when unknown.
    var title: (String) -> String? = { _ in nil }
}

enum ControlTopologyMapper {
    /// `selectedTab` answers the tab a window shows for a pane (app-local);
    /// `pages` what the app knows of page tabs (bd cx-5xsi).
    static func topology(store: DaemonStore, selectedTab: (PaneModel) -> String?,
                         pages: ControlPageFacts = ControlPageFacts()) -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = store.isLoaded
        topology.daemonState = switch store.connectionState {
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
        // The groups the sidebar draws: the home session's personal groups
        // when it serves them (cx-qno.17), else the daemon's shared groups.
        let groups = store.personal.isLoaded ? store.personal.groups : store.groups
        topology.workspaceGroups = groups.map { group in
            ControlWorkspaceGroupInfo(id: group.id.rawValue, name: group.name, color: group.color, isCollapsed: group.collapsed)
        }
        topology.workspaces = store.workspaces.map { workspace(from: $0, selectedTab: selectedTab, pages: pages) }
        return topology
    }

    static func workspace(from model: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                          pages: ControlPageFacts = ControlPageFacts()) -> ControlWorkspaceInfo {
        var info = ControlWorkspaceInfo(
            id: model.id,
            handle: model.handle.description,
            name: model.displayName,
            title: model.title,
            color: model.color,
            icon: model.icon,
            groupID: model.group?.rawValue,
            unreadCount: model.unreadCount,
            screens: model.screens.map { screen in
                ControlScreenInfo(id: screen.id, handle: screen.handle.description, name: screen.name,
                                  zoomedPaneID: screen.zoomedPane.flatMap { handle in screen.pane(handle)?.id },
                                  panes: screen.panes.map { pane(from: $0, selectedTab: selectedTab, pages: pages) })
            }
        )
        info.resourceID = model.resourceID?.rawValue
        return info
    }

    static func pane(from model: PaneModel, selectedTab: (PaneModel) -> String?,
                     pages: ControlPageFacts = ControlPageFacts()) -> ControlPaneInfo {
        var info = ControlPaneInfo(
            id: model.id,
            handle: model.handle.description,
            name: model.name,
            selectedTabID: selectedTab(model),
            tabs: model.tabs.map { tab($0, pages: pages) },
            tabGroups: model.tabGroups.map { group in
                ControlTabGroupInfo(id: group.id.rawValue, name: group.name, color: group.color, isCollapsed: group.collapsed,
                                    memberIDs: group.members.map { member in
                                        switch member {
                                        case .surface(let surface): model.tabs.first { $0.surface == surface }?.id ?? surface.description
                                        case .tab(let resource): resource.rawValue
                                        }
                                    })
            }
        )
        info.pageTabs = pages.appOnlyTabs(model)
        return info
    }

    static func tab(_ model: TabModel, pages: ControlPageFacts = ControlPageFacts()) -> ControlTabInfo {
        let kind = switch model.kind {
        case .pty: "terminal"
        case .browser: "browser"
        case .remoteTerminal: "remote-terminal"
        case .conversation: "conversation"
        case .other(let value): value
        }
        var info = ControlTabInfo(
            id: model.id,
            surface: model.surface.description,
            kind: kind,
            title: model.displayTitle,
            name: model.name,
            terminalID: model.terminalID?.rawValue,
            columns: model.size?.cols,
            rows: model.size?.rows,
            cwd: model.cwd,
            url: model.url,
            gitBranch: model.gitBranch,
            isPinned: model.pinned,
            isDead: model.dead,
            hasUnread: model.hasUnread,
            tabGroupID: model.tabGroup?.rawValue,
            agentState: model.agent?.state.rawValue
        ).withTerminalResource(model.terminalResourceID?.rawValue)
        info.agent = model.agent?.agent
        info.remoteSessionID = model.remote?.sessionID
        info.remoteTerminalID = model.remote?.terminalID.rawValue
        if model.kind == .browser { info.browserProfileID = model.snapshot.browserProfileID ?? "default" }
        info.agentSessionID = model.snapshot.conversation?.agentSession?.session
        // A store page tab (`page-tabs-v1`): the daemon titles it about:blank; the page names it.
        if let page = model.page {
            info.page = page
            if let title = pages.title(page) { info.title = title }
        }
        return info
    }
}
