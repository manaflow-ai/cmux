public import CmuxMobileHost
public import CmuxNextDaemon

/// Projects the daemon's tree onto `workspace:<host>` state (a0-rpc.md 5.2,
/// b5-mac-host.md section 6). Ids are the daemon's durable public resource
/// ids (`ws_…`, `pane_…`, `tab_…`, `term_…`); an entity without one is not
/// addressable from the phone and is left out. Arrangement only: selection,
/// focus and sizes are view state and never leave the Mac.
public struct MobileTreeProjection: Sendable {
    public let hostID: String

    public init(hostID: String) {
        self.hostID = hostID
    }

    public func state(_ tree: DaemonTree) -> MobileWorkspaceState {
        var order = 0
        var workspaces: [MobileWorkspace] = []
        for workspace in tree.workspaces where !workspace.isHome {
            guard let id = workspace.resourceID?.rawValue else { continue }
            let panes = workspace.screens.flatMap(\.panes).compactMap(pane)
            workspaces.append(MobileWorkspace(id: id, name: workspace.displayName, color: workspace.color,
                                              pinned: workspace.pinned ? true : nil, order: order, panes: panes))
            order += 1
        }
        return MobileWorkspaceState(host: hostID, workspaces: workspaces)
    }

    private func pane(_ pane: PaneSnapshot) -> MobilePane? {
        guard !pane.dead, let id = pane.resourceID?.rawValue else { return nil }
        return MobilePane(id: id, tabs: pane.tabs.compactMap(tab))
    }

    private func tab(_ tab: TabSnapshot) -> MobileTab? {
        guard let id = tab.tabResourceID?.rawValue else { return nil }
        let kind: MobileTab.Kind
        var terminal: String?
        var url: String?
        switch tab.kind {
        case .pty:
            kind = .terminal
            terminal = tab.terminalResourceID?.rawValue
        case .browser:
            kind = .browser
            url = tab.url
        case .conversation:
            kind = .agent
        case .remoteTerminal, .other:
            kind = .other
        }
        let unread = tab.notification?.unread == true ? 1 : 0
        let status: MobileTab.Status = tab.dead ? .error : .idle
        return MobileTab(id: id, kind: kind, title: tab.displayTitle, terminal: terminal, url: url,
                         status: status, unread: unread)
    }

    /// The tab whose terminal is `terminal` (`term_…`), with the tree's generation.
    public func tab(showing terminal: String, in tree: DaemonTree) -> TabSnapshot? {
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.terminalResourceID?.rawValue == terminal }) { return tab }
            }
        }
        return nil
    }

    public func workspaceKey(_ id: String, in tree: DaemonTree) -> WorkspaceKey? {
        tree.workspaces.first { $0.resourceID?.rawValue == id }?.key
    }

    public func surface(ofTab id: String, in tree: DaemonTree) -> SurfaceID? {
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.tabResourceID?.rawValue == id }) { return tab.surface }
            }
        }
        return nil
    }
}
