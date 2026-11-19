public import CmuxNextDaemon
public import CmuxNextDaemonService

/// A workspace create shown at the press: the work that confirms it with the daemon, and the way to take it back.
public struct ShownWorkspaceCreate {
    /// Sends the create, asking again on a late reply until the instant given; returns the workspace key. Throws
    /// when the create failed (the stand-in is gone then).
    public let confirm: @MainActor (ContinuousClock.Instant) async throws -> String
    /// The create never ran (a close took it first): the stand-in goes.
    public let abandon: @MainActor () -> Void

    /// - Parameters:
    ///   - confirm: The daemon work; it returns the workspace key.
    ///   - abandon: Removes the stand-in when the create never ran.
    public init(confirm: @escaping @MainActor (ContinuousClock.Instant) async throws -> String, abandon: @escaping @MainActor () -> Void) {
        self.confirm = confirm
        self.abandon = abandon
    }
}

extension WorkspaceSpawn {
    /// Shows this browser workspace (``firstBrowser``) in `daemon`'s store now, before any await: the workspace and
    /// its page are there in the press's turn (`BrowserWorkspaceStandIn`), and the returned work sends the one
    /// `create-workspace {first_tab}` request behind them. On the reply the daemon's tab takes the stand-in's place
    /// and `handOver` moves the page to it in the same turn, so the page the person saw start is never rebuilt.
    ///
    /// - Parameters:
    ///   - key: The workspace key the create sends.
    ///   - name: The workspace's name, shown from the first frame.
    ///   - daemon: The daemon that makes the workspace.
    ///   - create: Sends the create for the tab given and returns the daemon's reply.
    ///   - handOver: Moves the stand-in tab's page (its tab id) to the daemon's tab.
    /// - Returns: The work to run in the window's create lane; nil when the create must wait for the daemon (not a
    ///   browser workspace, a daemon without `workspace-first-tab-v1`, or a workspace browser profile to set first).
    @MainActor
    public func showFirstBrowser(_ key: WorkspaceKey, name: String, on daemon: DaemonService,
                                 create: @escaping @MainActor (WorkspaceFirstBrowserTab, DaemonConnection) async throws -> WorkspaceMutationResult,
                                 handOver: @escaping @MainActor (String, TabModel) -> Void) -> ShownWorkspaceCreate? {
        guard let tab = firstBrowser, command == nil, browserProfile == nil,
              daemon.supports(DaemonCapability.workspaceFirstTab.rawValue) else { return nil }
        let store = daemon.store, spawn = self
        let shown = BrowserWorkspaceStandIn(key: key, name: name, url: tab.url, engine: tab.engine.rawValue, profile: tab.profileID, in: store)
        return ShownWorkspaceCreate(confirm: { _ in
            let connection: DaemonConnection, created: WorkspaceMutationResult
            do {
                guard let live = daemon.connection else { throw DaemonError.notConnected }
                connection = live
                created = try await create(tab, live)
            } catch {
                shown.failed()
                throw error
            }
            if let first = created.firstTab {
                // The records hold the daemon's tab once the store applied what came before the reply.
                let sequence = await connection.eventSequence()
                await store.applied(through: sequence)
                shown.confirmed(surface: first.surface, at: sequence) { surface in
                    if let made = store.tab(surface: surface) { handOver(shown.tab, made) }
                }
            } else {
                shown.failed() // a replayed create made no tab now: the daemon's records alone show the workspace
            }
            return try await spawn.madeFirstBrowser(created, on: connection)
        }, abandon: { shown.failed() })
    }
}
