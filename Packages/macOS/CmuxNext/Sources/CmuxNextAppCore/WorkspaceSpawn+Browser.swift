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
        var spawn = WorkspaceSpawn(name: name, profile: profile)
        spawn.firstBrowser = tab
        spawn.onFirstBrowser = configure
        spawn.onFirstTerminal = { connection, terminal in
            guard let pane = terminal.pane else { return }
            let created = try await connection.newFrontendBrowserTab(url: tab.url, engine: tab.engine, in: pane, title: tab.title, profileID: tab.profileID)
            try await configure?(connection, created)
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
        return spawn
    }

    /// Runs ``onFirstBrowser`` on the tab `created` came with (a `create-workspace {first_tab}` reply).
    ///
    /// - Returns: The created workspace's key.
    public func madeFirstBrowser(_ created: WorkspaceMutationResult, on connection: DaemonConnection) async throws -> String {
        if let made = created.firstTab { try await onFirstBrowser?(connection, made) }
        return created.key.rawValue
    }
}
