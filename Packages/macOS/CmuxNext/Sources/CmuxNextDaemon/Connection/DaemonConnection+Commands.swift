public import Foundation

/// Convenience wrappers for the commands the GUI issues. Durable workspace
/// mutations get a fresh `mutation_id` per call; pass an explicit
/// `MutationIdentity` to the request types when retrying one logical change.
extension DaemonConnection {
    /// Stable frontend identity for the exactly-once ledger.
    public static let origin = "cmux-next"

    /// A fresh mutation identity, or one derived from the running action's
    /// idempotency key (`DaemonCommandScope`), so a retried action replays.
    public func mutation() -> MutationIdentity {
        guard let derived = DaemonCommandScope.current?.nextMutationID() else { return MutationIdentity(origin: Self.origin) }
        return MutationIdentity(origin: Self.origin, mutationID: derived)
    }

    public func listWorkspaces() async throws -> DaemonTree {
        try await request(ListWorkspacesRequest())
    }

    // Workspaces

    @discardableResult
    public func createWorkspace(name: String? = nil, key: WorkspaceKey = .generate()) async throws -> WorkspaceMutationResult {
        try await request(CreateWorkspaceRequest(name: name, key: key, mutation: mutation()))
    }

    @discardableResult
    public func renameWorkspace(_ key: WorkspaceKey, to name: String) async throws -> WorkspaceMutationResult {
        try await request(RenameWorkspaceRequest(workspace: .key(key), name: name, mutation: mutation()))
    }

    @discardableResult
    public func moveWorkspace(_ key: WorkspaceKey, to index: Int) async throws -> WorkspaceMutationResult {
        try await request(MoveWorkspaceRequest(workspace: .key(key), index: index, mutation: mutation()))
    }

    @discardableResult
    public func setWorkspaceMetadata(_ key: WorkspaceKey, color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged,
                                     title: FieldUpdate<String> = .unchanged, pinned: Bool? = nil,
                                     markedUnread: Bool? = nil) async throws -> WorkspaceMetadataResult {
        try await request(SetWorkspaceMetadataRequest(workspace: .key(key), color: color, icon: icon, title: title, pinned: pinned,
                                                      markedUnread: markedUnread, mutation: mutation()))
    }

    /// Closes a workspace. `endTerminals` also ends, in the same daemon
    /// commit, each of its terminals not shown elsewhere and not kept; it is
    /// sent only to a daemon with `batch-close-v1` (see `supportsBatchClose`).
    @discardableResult
    public func closeWorkspace(_ key: WorkspaceKey, endTerminals: Bool = false) async throws -> WorkspaceMutationResult {
        try await request(CloseWorkspaceRequest(workspace: .key(key), endTerminals: endTerminals, mutation: mutation()))
    }

    /// Whether this daemon closes many tabs, and the terminals they end, in
    /// one commit (`close-tabs`, `end_terminals`).
    public var supportsBatchClose: Bool { identity?.supports(DaemonCapabilities.shared.batchClose) == true }

    /// Closes `surfaces` in one daemon commit (`batch-close-v1`). With
    /// `endTerminals`, each terminal whose tabs all close ends too, unless kept.
    @discardableResult
    public func closeTabs(_ surfaces: [SurfaceID], endTerminals: Bool = true,
                          transaction: ClientTransactionID? = nil) async throws -> CloseTabsResult {
        try await requestNew(CloseTabsRequest(surfaces: surfaces, endTerminals: endTerminals, transaction: transaction,
                                              mutation: mutation()))
    }

    // Terminals, tabs, panes, columns, screens

    /// `env` for a new terminal: the caller's, else the configured allowlist
    /// provider's when the daemon supports `terminal-env-v1`.
    func terminalEnvironment(_ explicit: [String: String]?) async -> [String: String]? {
        if let explicit { return explicit }
        guard identity?.supports(DaemonCapabilities.shared.terminalEnv) == true, let provider = configuration.terminalEnvironment else {
            return nil
        }
        let env = await provider()
        return env.isEmpty ? nil : env
    }

    /// Spawns a terminal in a workspace; creates its first screen/pane when
    /// empty. Its reserved id and workspace are named in `env`
    /// (`CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`) with `terminal-env-v1`.
    /// `keep` (`terminal-reap-v1`) keeps it after its last tab closes.
    @discardableResult
    public func createTerminal(in key: WorkspaceKey, cwd: String? = nil, argv: [String]? = nil, name: String? = nil,
                               size: CellSize? = nil, env: [String: String]? = nil, keep: Bool? = nil) async throws -> CreateTerminalResult {
        let terminal = TerminalID.generate()
        var env = await terminalEnvironment(env)
        if identity?.supports(DaemonCapabilities.shared.terminalEnv) == true {
            env = (env ?? [:]).merging(Self.placementEnvironment(workspace: key, terminal: terminal)) { _, placement in placement }
        }
        let keep = identity?.supports(DaemonCapabilities.shared.terminalReap) == true ? keep : nil
        return try await request(CreateTerminalRequest(workspace: .key(key), argv: argv, cwd: cwd, name: name, size: size,
                                                       terminalID: terminal, env: env, keep: keep, mutation: mutation()))
    }

    /// New terminal tab in `pane` (the daemon's focused pane when nil).
    @discardableResult
    public func newTab(in pane: PaneID?, options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        if supportsPlacementEnv {
            let options = await placed(options)
            return Self.created(try await request(NewTabRequest(pane: pane, options: options)), options: options)
        }
        if let pane, let placed = try await spawnPlacedByMove(options, into: .tab(pane)) { return placed }
        var options = served(options)
        options.env = await terminalEnvironment(options.env)
        return try await request(NewTabRequest(pane: pane, options: options))
    }

    /// Splits `pane` with a new terminal. With `tab`, moves that existing tab
    /// into the new pane instead (`move-tab-to-split`, right or bottom edge)
    /// and returns it; `options` then do not apply.
    @discardableResult
    public func split(_ pane: PaneID, direction: SplitDirection, movingTab tab: SurfaceID? = nil,
                      options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        if let tab {
            let moved = try await moveTabToSplit(tab, pane: pane, edge: direction == .right ? .right : .bottom)
            return SurfaceCreated(surface: moved.surface ?? tab)
        }
        if supportsPlacementEnv {
            let options = await placed(options)
            return Self.created(try await request(SplitRequest(pane: pane, direction: direction, options: options)), options: options)
        }
        if let placed = try await spawnPlacedByMove(options, into: .split(pane, direction)) { return placed }
        var options = served(options)
        options.env = await terminalEnvironment(options.env)
        return try await request(SplitRequest(pane: pane, direction: direction, options: options))
    }

    /// New pane in `pane`'s column. `cwd`, `env`, and `keep` reach the
    /// daemon only with `terminal-placement-env-v1`.
    @discardableResult
    public func newPaneInColumn(of pane: PaneID, options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        guard supportsPlacementEnv else { return try await request(NewPaneRequest(pane: pane, options: served(options))) }
        let options = await placed(options)
        return Self.created(try await request(NewPaneRequest(pane: pane, options: options)), options: options)
    }

    /// New scrolling column right of `pane`'s. `cwd`, `env`, and `keep`
    /// reach the daemon only with `terminal-placement-env-v1`.
    @discardableResult
    public func newColumn(rightOf pane: PaneID, width: Double? = nil, options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        guard supportsPlacementEnv else { return try await request(NewColumnRequest(pane: pane, width: width, options: served(options))) }
        let options = await placed(options)
        return Self.created(try await request(NewColumnRequest(pane: pane, width: width, options: options)), options: options)
    }

    @discardableResult
    public func newScreen(in workspace: WorkspaceHandle?, size: CellSize? = nil) async throws -> SurfaceCreated {
        try await request(NewScreenRequest(workspace: workspace, size: size))
    }

    public func closeTab(_ surface: SurfaceID) async throws { _ = try await request(CloseTabRequest(surface: surface)) }
    public func closePane(_ pane: PaneID, endTerminals: Bool = false) async throws {
        _ = try await request(ClosePaneRequest(pane: pane, endTerminals: endTerminals))
    }
    public func closeScreen(_ screen: ScreenID, endTerminals: Bool = false) async throws {
        _ = try await request(CloseScreenRequest(screen: screen, endTerminals: endTerminals))
    }

    public func closeTerminal(_ terminal: TerminalID, incarnation: TerminalIncarnation? = nil) async throws {
        _ = try await request(CloseTerminalRequest(terminalID: terminal, terminalIncarnation: incarnation, mutation: mutation()))
    }

    /// Needs `tab-metadata-v1`; a daemon without it (a Cloud image's build)
    /// gets `missingCapabilities` and no request.
    @discardableResult
    public func setTabPinned(_ surface: SurfaceID, _ pinned: Bool) async throws -> SetTabPinnedRequest.Response {
        guard identity?.supports(DaemonCapabilities.shared.tabMetadata) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.tabMetadata])
        }
        return try await request(SetTabPinnedRequest(surface: surface, pinned: pinned))
    }

    /// App-rendered browser tab (`frontend-browser-tabs-v1`).
    @discardableResult
    public func newFrontendBrowserTab(url: String, engine: BrowserEngine, in pane: PaneID?, title: String? = nil,
                                      profileID: String? = nil) async throws -> NewFrontendBrowserTabRequest.Response {
        try await request(NewFrontendBrowserTabRequest(url: url, engine: engine, pane: pane, title: title, profileID: profileID))
    }

    @discardableResult
    public func updateFrontendBrowserTab(_ surface: SurfaceID, url: String? = nil, title: String? = nil,
                                         faviconURL: FieldUpdate<String> = .unchanged) async throws -> UpdateFrontendBrowserTabRequest.Response {
        try await request(UpdateFrontendBrowserTabRequest(surface: surface, url: url, title: title, faviconURL: faviconURL))
    }

    public func renameTab(_ surface: SurfaceID, to name: String) async throws { _ = try await request(RenameTabRequest(surface: surface, name: name)) }
    public func renamePane(_ pane: PaneID, to name: String) async throws { _ = try await request(RenamePaneRequest(pane: pane, name: name)) }
    public func renameScreen(_ screen: ScreenID, to name: String) async throws { _ = try await request(RenameScreenRequest(screen: screen, name: name)) }

    // Layout

    public func setSplitRatio(_ split: SplitID, ratio: Double, transaction: UInt64? = nil) async throws {
        _ = try await request(SetSplitRatioRequest(split: split, ratio: ratio, transaction: transaction))
    }

    public func setColumnWidth(of pane: PaneID, width: Double, transaction: UInt64? = nil) async throws {
        _ = try await request(SetColumnWidthRequest(pane: pane, width: width, transaction: transaction))
    }

    /// `set-column-dock` for the column holding `pane`; nil unpins it.
    public func setColumnDock(of pane: PaneID, dock: DockSnapshot?, transaction: UInt64? = nil) async throws {
        _ = try await request(SetColumnDockRequest(pane: pane, dock: dock, transaction: transaction))
    }

    public func swapPane(_ pane: PaneID, with target: SwapTarget) async throws {
        _ = try await request(SwapPaneRequest(pane: pane, target: target))
    }

    @discardableResult
    public func zoomPane(_ pane: PaneID?, mode: ZoomPaneRequest.Mode = .toggle) async throws -> ZoomPaneRequest.Response {
        try await request(ZoomPaneRequest(pane: pane, mode: mode))
    }

    @discardableResult
    public func undoLayout(pane: PaneID, confirmingRevision revision: UInt64? = nil) async throws -> UndoLayoutRequest.Response {
        try await request(UndoLayoutRequest(pane: pane, revision: revision, confirmClose: revision == nil ? nil : true))
    }

    // Input and sizing on the control connection (views use TerminalAttachment)

    public func send(_ surface: SurfaceID, text: String? = nil, bytes: Data? = nil, paste: Bool = false) async throws {
        _ = try await request(SendInputRequest(surface: surface, text: text, bytes: bytes, paste: paste ? true : nil))
    }

    public func sendKeys(_ surface: SurfaceID, _ keys: [String]) async throws {
        _ = try await request(SendKeyRequest(surface: surface, keys: keys))
    }

    public func setDefaultColors(fg: String?, bg: String?, cursor: String?) async throws {
        _ = try await request(SetDefaultColorsRequest(fg: fg, bg: bg, cursor: cursor))
    }

    // Projections

    public func frontendProjection(subject: String, scope: ProjectionScope = .personal) async throws -> FrontendProjection {
        try await request(GetFrontendProjectionRequest(frontend: Self.origin, scope: scope, subjectKey: subject))
    }

    @discardableResult
    public func putFrontendProjection(subject: String, scope: ProjectionScope = .personal, schemaVersion: UInt32,
                                      projection: JSONValue, expectedRevision: UInt64? = nil) async throws -> FrontendProjection {
        try await request(PutFrontendProjectionRequest(
            frontend: Self.origin, scope: scope, subjectKey: subject, schemaVersion: schemaVersion,
            projection: projection, expectedProjectionRevision: expectedRevision, mutation: mutation()))
    }

    // Agents and notifications

    public func agents() async throws -> [AgentStatus] {
        try await request(ListAgentsRequest()).agents
    }

    @discardableResult
    /// Posts a notification. `source` (`notification-source-v1`: `cli`,
    /// `terminal`, `agent`, `daemon`) reaches daemons that serve it.
    public func notify(title: String, body: String = "", level: NotificationLevel = .info, surface: SurfaceID? = nil,
                       source: String? = nil) async throws -> NotificationID {
        let source = identity?.supports(DaemonCapabilities.shared.notificationSource) == true ? source : nil
        return try await request(NotifyRequest(title: title, body: body, level: level, surface: surface, source: source))
            .notification
    }

    /// Clears a tab's unread marker without selecting it (`notification-ack-v1`).
    @discardableResult
    public func acknowledgeNotifications(of surface: SurfaceID) async throws -> AckTabNotificationsRequest.Response {
        try await requestNew(AckTabNotificationsRequest(surface: surface))
    }

    public func notificationLedger(limit: Int? = nil) async throws -> [ListNotificationsRequest.Entry] {
        try await requestNew(ListNotificationsRequest(limit: limit)).notifications
    }

    /// Hands the session off (the daemon exits). With `endTerminals`
    /// (`terminal-reap-v1`) it first ends every terminal and waits for their
    /// hosts, so no PTY outlives it; returns the ended count then.
    ///
    /// The end-terminals form runs on its own short-lived socket, for two
    /// reasons. Callers (test teardown) must `close()` this connection
    /// first: otherwise the daemon's exit reads as EOF and the reconnect
    /// runs `server ensure`, starting a fresh daemon that outlives them. And
    /// it takes seconds (each host is awaited), longer than the control
    /// request deadline. (The subscribed socket itself is safe: during a
    /// pending handoff the daemon answers a pipelined request, such as a
    /// store resync, with an error. d1aa608 and older closed the socket
    /// instead, losing the shutdown reply.)
    @discardableResult
    public func shutdownDaemon(endTerminals: Bool = false, keepLayout: Bool = false) async throws -> ShutdownDaemonRequest.Response {
        guard let identity else { throw DaemonError.notConnected }
        guard endTerminals else {
            return try await request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
        }
        guard identity.supports(DaemonCapabilities.shared.terminalReap) else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.terminalReap])
        }
        guard let endpoint else { throw DaemonError.notConnected }
        let transport = try LineTransport(path: endpoint.socketPath)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        let request = ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true,
                                            keepLayout: keepLayout ? true : nil)
        return try await Self.perform(request, on: transport, timeout: Self.endTerminalsTimeout)
    }

    /// Quit's end choices (`SessionEnding.run`): ends every terminal and
    /// stops the daemon; End Everything first closes every workspace but
    /// Home. Returns every step that failed.
    public func endSessionsAndStop(deletingWorkspaces: Bool = false, keepingLayout: Bool = false) async -> EndedSessions {
        await SessionEnding.run(on: self, deletingWorkspaces: deletingWorkspaces, keepingLayout: keepingLayout)
    }

    /// Deadline for `shutdown-daemon end_terminals`, which awaits every host.
    public static let endTerminalsTimeout: Duration = .seconds(60)
}
