import CmuxNextControl
import CmuxNextDaemon

/// Maps the daemon mirror into the control socket's value topology. Pure;
/// the publisher calls it inside Observation tracking so every property it
/// reads schedules the next publish when it changes.
enum ControlTopologyMapper {
    /// `selectedTab` answers the tab a window shows for a pane (app-local).
    static func topology(store: DaemonStore, selectedTab: (PaneModel) -> String?) -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = store.isLoaded
        topology.daemonState = switch store.connectionState {
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
        topology.workspaceGroups = store.groups.map { group in
            ControlWorkspaceGroupInfo(id: group.id.rawValue, name: group.name, color: group.color, isCollapsed: group.collapsed)
        }
        topology.workspaces = store.workspaces.map { workspace(from: $0, selectedTab: selectedTab) }
        return topology
    }

    static func workspace(from model: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> ControlWorkspaceInfo {
        ControlWorkspaceInfo(
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
                                  panes: screen.panes.map { pane(from: $0, selectedTab: selectedTab) })
            }
        )
    }

    static func pane(from model: PaneModel, selectedTab: (PaneModel) -> String?) -> ControlPaneInfo {
        ControlPaneInfo(
            id: model.id,
            handle: model.handle.description,
            name: model.name,
            selectedTabID: selectedTab(model),
            tabs: model.tabs.map(tab),
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
    }

    static func tab(_ model: TabModel) -> ControlTabInfo {
        let kind = switch model.kind {
        case .pty: "terminal"
        case .browser: "browser"
        case .other(let value): value
        }
        return ControlTabInfo(
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
        )
    }
}
