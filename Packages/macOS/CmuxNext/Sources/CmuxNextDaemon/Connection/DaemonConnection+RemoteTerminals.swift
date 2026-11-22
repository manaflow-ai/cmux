import Foundation

/// Remote-terminal tabs (`remote-terminal-tabs-v1`, plans/cmux-next/
/// data-model.md 1.2b): references in the home session's layout to
/// terminals that run on another session.
extension DaemonConnection {
    private func requireRemoteTerminalTabs() throws {
        guard identity?.supports(DaemonCapability.remoteTerminalTabs.rawValue) == true else {
            throw DaemonError.missingCapabilities([DaemonCapability.remoteTerminalTabs.rawValue])
        }
    }

    /// A remote-terminal tab for `ref` in `pane` (home session).
    @discardableResult
    public func newRemoteTerminalTab(_ ref: RemoteTerminalRef, in pane: PaneID?, title: String? = nil,
                                     size: CellSize? = nil) async throws -> NewRemoteTerminalTabRequest.Response {
        try requireRemoteTerminalTabs()
        return try await request(NewRemoteTerminalTabRequest(ref, pane: pane, title: title, size: size))
    }

    /// Stores the placeholder's title and snapshot (bounded to 64 KiB).
    @discardableResult
    public func updateRemoteTerminalTab(_ surface: SurfaceID, title: String? = nil, sessionName: String? = nil,
                                        snapshot: String? = nil) async throws -> UpdateRemoteTerminalTabRequest.Response {
        try requireRemoteTerminalTabs()
        return try await request(UpdateRemoteTerminalTabRequest(
            surface: surface, title: title.map(FieldUpdate.set) ?? .unchanged, sessionName: sessionName,
            snapshot: snapshot.map { .set(UpdateRemoteTerminalTabRequest.bounded($0)) } ?? .unchanged))
    }

    public func remoteTerminalSnapshot(_ surface: SurfaceID) async throws -> String? {
        try requireRemoteTerminalTabs()
        return try await request(RemoteTerminalSnapshotRequest(surface: surface)).snapshot
    }

    /// A new kept terminal with no tab on this session (its only view
    /// lives in another session's layout): `create-terminal {detached}`.
    public func createDetachedTerminal(cwd: String? = nil, size: CellSize? = nil) async throws -> CreateDetachedTerminalRequest.Response {
        guard identity?.supports(DaemonCapability.detachedTerminals.rawValue) == true else {
            throw DaemonError.missingCapabilities([DaemonCapability.detachedTerminals.rawValue])
        }
        let terminal = TerminalID.generate()
        var env = await terminalEnvironment(nil)
        if identity?.supports(DaemonCapability.terminalEnv.rawValue) == true {
            env = (env ?? [:]).merging(Self.placementEnvironment(workspace: nil, terminal: terminal)) { _, placement in placement }
        }
        return try await request(CreateDetachedTerminalRequest(cwd: cwd, size: size, terminalID: terminal, env: env, mutation: mutation()))
    }

    /// A kept terminal with no tab on a daemon without
    /// `detached-terminals-v1`: created in workspace `key` with `keep`, then
    /// its tab closes (the tab exists for one round trip).
    public func createUnplacedTerminal(in key: WorkspaceKey, cwd: String? = nil,
                                       size: CellSize? = nil) async throws -> (terminal: TerminalID, resource: ResourceID?) {
        guard identity?.supports(DaemonCapability.terminalReap.rawValue) == true else {
            throw DaemonError.missingCapabilities([DaemonCapability.terminalReap.rawValue])
        }
        let created = try await createTerminal(in: key, cwd: cwd, size: size, keep: true)
        if let surface = created.surface { try await closeTab(surface) }
        return (created.terminalID, try await keepTerminal(created.terminalID))
    }

    /// Marks `terminal` kept (a view in another session's layout is its
    /// only placement) and returns its public `term_` id, which
    /// `attach-identity-v1` resolves; nil from daemons that do not report it.
    public func keepTerminal(_ terminal: TerminalID) async throws -> ResourceID? {
        try await setTerminalKeep(.terminal(terminal), keep: true).terminalResourceID
    }

    /// Keeps `terminal` (``keepTerminal(_:)``) on a daemon that can reap it, before its last tab here closes.
    ///
    /// A daemon without `terminal-reap-v1` ends no tabless terminal and stores no keep, so it is not asked
    /// and the result is nil. On any other daemon the keep's failure is thrown: a caller that closes the
    /// terminal's last tab must not close it then, or a reaping daemon ends the terminal after its grace.
    ///
    /// - Parameter terminal: The terminal to keep.
    /// - Returns: The terminal's public id when the daemon names it; nil from a daemon without `terminal-reap-v1`.
    /// - Throws: The keep's failure, for example `terminal_not_found` for a terminal this daemon does not have.
    public func keepTerminalIfReaping(_ terminal: TerminalID) async throws -> ResourceID? {
        guard identity?.supports(DaemonCapability.terminalReap.rawValue) == true else { return nil }
        return try await keepTerminal(terminal)
    }
}
