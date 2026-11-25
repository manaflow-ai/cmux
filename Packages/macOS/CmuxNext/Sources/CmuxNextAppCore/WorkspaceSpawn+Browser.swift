public import CmuxNextDaemon

extension WorkspaceSpawn {
    /// A workspace whose only tab is the browser tab `tab`. On a daemon that serves `workspace-first-tab-v1` it is
    /// one request and no terminal exists at any point; `configure` works on the tab. An older daemon makes a
    /// terminal, opens the tab beside it and closes the terminal.
    ///
    /// - Parameters:
    ///   - tab: The browser tab the workspace opens with.
    ///   - name: The workspace's name; nil: the daemon names it.
    ///   - profile: The space it is pinned to; nil: its window's space.
    ///   - configure: Work on the created tab, part of the create (its failure is the create's).
    /// - Returns: The spawn to hand to the window's one create path.
    public static func browser(_ tab: WorkspaceFirstBrowserTab, name: String? = nil, profile: ProfileID? = nil,
                               then configure: (@Sendable (DaemonConnection, NewFrontendBrowserTabRequest.Response) async throws -> Void)? = nil) -> WorkspaceSpawn {
        browsers([tab], name: name, profile: profile, background: nil) { connection, _, created in try await configure?(connection, created) }
    }

    /// A workspace whose tabs are the browser tabs `tabs`, in order, the first one selected. On a daemon that
    /// serves `workspace-first-tab-v1` the first tab comes with the create and each later one is one request sent
    /// to the workspace: no terminal exists at any point. An older daemon makes a terminal, opens the tabs beside
    /// it and closes the terminal.
    ///
    /// - Parameters:
    ///   - tabs: The tabs, at least one (none: a plain terminal workspace).
    ///   - name: The workspace's name; nil: the daemon names it.
    ///   - profile: The space it is pinned to; nil: its window's space.
    ///   - background: `false` keeps the tabs after the first in the background (`frontend-browser-activate-v1`);
    ///     nil when the daemon does not serve that field.
    ///   - each: Work on each created tab with its index in `tabs`, part of the create.
    /// - Returns: The spawn to hand to the window's one create path.
    public static func browsers(_ tabs: [WorkspaceFirstBrowserTab], name: String? = nil, profile: ProfileID? = nil, background: Bool?,
                                each: (@Sendable (DaemonConnection, Int, NewFrontendBrowserTabRequest.Response) async throws -> Void)? = nil) -> WorkspaceSpawn {
        var spawn = WorkspaceSpawn(name: name, profile: profile)
        spawn.firstBrowser = tabs.first
        spawn.moreBrowsers = Array(tabs.dropFirst())
        spawn.moreBrowsersActivate = background
        spawn.onBrowserTab = each
        spawn.onFirstTerminal = { connection, terminal in
            guard let pane = terminal.pane else { return }
            for (index, tab) in tabs.enumerated() {
                let created = try await connection.newFrontendBrowserTab(url: tab.url, engine: tab.engine, in: pane, title: tab.title,
                                                                         profileID: tab.profileID, activate: index == 0 ? nil : background)
                try await each?(connection, index, created)
            }
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
        return spawn
    }

    /// The requests that follow a `create-workspace {first_tab}` reply: ``onBrowserTab`` on the tab `created` came
    /// with, then each of ``moreBrowsers`` as one request sent to the workspace (`frontend-browser-tab-workspace-v1`).
    ///
    /// - Returns: The created workspace's key.
    public func madeFirstBrowser(_ created: WorkspaceMutationResult, on connection: DaemonConnection) async throws -> String {
        if let made = created.firstTab { try await onBrowserTab?(connection, 0, made) }
        for (offset, tab) in moreBrowsers.enumerated() {
            let made = try await connection.newFrontendBrowserTab(moreBrowserRequest(tab), inWorkspace: created.workspace)
            try await onBrowserTab?(connection, offset + 1, made)
        }
        return created.key.rawValue
    }

    /// The request for `tab`, a tab after the first (the connection adds the workspace).
    public func moreBrowserRequest(_ tab: WorkspaceFirstBrowserTab) -> NewFrontendBrowserTabRequest {
        NewFrontendBrowserTabRequest(url: tab.url, engine: tab.engine, title: tab.title,
                                     profileID: tab.profileID, activate: moreBrowsersActivate)
    }
}
