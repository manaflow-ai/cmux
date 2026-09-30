import Foundation

/// Remote-terminal tabs (`remote-terminal-tabs-v1`, plans/cmux-next/
/// data-model.md 1.2b): references in the home session's layout to
/// terminals that run on another session.
extension DaemonConnection {
    private func requireRemoteTerminalTabs() throws {
        guard identity?.supports(DaemonCapabilities.remoteTerminalTabs) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.remoteTerminalTabs])
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

    /// A new kept terminal with no tab on this session (its only view will
    /// live in another session's layout): created in workspace `key` with
    /// `keep`, then its tab closes, which never ends a kept terminal. The
    /// daemon has no placement-free create (creation is bound to a
    /// workspace), so the tab exists for one round trip.
    public func createUnplacedTerminal(in key: WorkspaceKey, cwd: String? = nil,
                                       size: CellSize? = nil) async throws -> (terminal: TerminalID, resource: ResourceID?) {
        guard identity?.supports(DaemonCapabilities.terminalReap) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.terminalReap])
        }
        let created = try await createTerminal(in: key, cwd: cwd, size: size, keep: true)
        if let surface = created.surface { try await closeTab(surface) }
        let kept = try await keepTerminal(created.terminalID)
        return (created.terminalID, kept)
    }

    /// Marks `terminal` kept (a view in another session's layout is its
    /// only placement) and returns its public `term_` id, which
    /// `attach-identity-v1` resolves; nil from daemons that do not report it.
    public func keepTerminal(_ terminal: TerminalID) async throws -> ResourceID? {
        try await setTerminalKeep(.terminal(terminal), keep: true).terminalResourceID
    }
}
