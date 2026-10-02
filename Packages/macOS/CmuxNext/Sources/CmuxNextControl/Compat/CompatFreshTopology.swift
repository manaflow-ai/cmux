import CmuxNextDaemon
import Foundation

/// A `ControlTopology` from a fresh `list-workspaces`, for compat methods
/// that must read their own writes (a creation verb reporting the refs of
/// what it just made). App-local state (windows, focus, tab selection) is
/// copied from the published snapshot, which the daemon does not know.
/// The tree is the home session's; remote sessions' workspaces stay as the
/// snapshot has them.
enum CompatFreshTopology {
    static func make(tree: DaemonTree, appState snapshot: ControlTopology) -> ControlTopology {
        var topology = snapshot
        topology.isLoaded = true
        let selected = Dictionary(snapshot.workspaces.flatMap(\.panes).map { ($0.id, $0.selectedTabID) }, uniquingKeysWith: { a, _ in a })
        let homeID = snapshot.homeSession?.id
        let remote = snapshot.workspaces.filter { $0.sessionID != nil && $0.sessionID != homeID }
        let home = tree.workspaces.map { workspace -> ControlWorkspaceInfo in
            ControlWorkspaceInfo(
                id: workspace.key?.rawValue ?? "handle:\(workspace.id.rawValue)", handle: workspace.id.description,
                name: workspace.displayName, title: workspace.title, color: workspace.color, icon: workspace.icon,
                groupID: workspace.group?.rawValue, unreadCount: workspace.unreadCount ?? 0,
                screens: workspace.screens.map { screen in
                    let byID = Dictionary(screen.panes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    var order = screen.columns.isEmpty ? screen.layout.paneIDs : screen.columns.flatMap(\.layout.paneIDs)
                    order += screen.panes.map(\.id).filter { !order.contains($0) }
                    let panes = order.compactMap { byID[$0] }.filter { !$0.dead }
                    return ControlScreenInfo(
                        id: screen.resourceID?.rawValue ?? "screen:\(screen.id.rawValue)", handle: screen.id.description,
                        name: screen.name, zoomedPaneID: screen.zoomedPane.flatMap { byID[$0] }.map(paneID),
                        panes: panes.map { pane in
                            let id = paneID(pane)
                            let tabs = pane.tabs.map(tab)
                            let remembered = selected[id] ?? nil
                            let fallback = pane.tabs.indices.contains(pane.activeTab) ? tabs[pane.activeTab].id : tabs.first?.id
                            return ControlPaneInfo(id: id, handle: pane.id.description, name: pane.name,
                                                   selectedTabID: remembered.flatMap { r in tabs.contains { $0.id == r } ? r : nil } ?? fallback,
                                                   tabs: tabs)
                        })
                })
        }
        topology.workspaces = home + remote
        return topology
    }

    static func paneID(_ pane: PaneSnapshot) -> String { pane.resourceID?.rawValue ?? "pane:\(pane.id.rawValue)" }

    static func tab(_ tab: TabSnapshot) -> ControlTabInfo {
        let kind = switch tab.kind {
        case .pty: "terminal"
        case .browser: "browser"
        case .remoteTerminal: "remote-terminal"
        case .conversation: "conversation"
        case .other(let value): value
        }
        var info = ControlTabInfo(
            id: tab.tabResourceID?.rawValue ?? tab.terminalID.map { "terminal:\($0.rawValue)" } ?? "surface:\(tab.surface.rawValue)",
            surface: tab.surface.description, kind: kind, title: tab.displayTitle, name: tab.name, terminalID: tab.terminalID?.rawValue,
            columns: tab.size?.cols, rows: tab.size?.rows, cwd: tab.cwd, url: tab.url, gitBranch: tab.gitBranch, isPinned: tab.pinned,
            isDead: tab.dead, hasUnread: tab.notification?.unread ?? false, tabGroupID: tab.tabGroup?.rawValue)
        info.remoteSessionID = tab.remote?.sessionID
        info.remoteTerminalID = tab.remote?.terminalID.rawValue
        return info
    }
}
