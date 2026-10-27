import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWorkspaceRepair

extension EmptyWorkspaceRepair {
    /// The repair of `daemon`'s workspaces: its connection creates and
    /// closes, its registry gives the cause, its store the epoch.
    convenience init(daemon: DaemonService) {
        self.init(store: daemon.store, create: { [weak daemon] key in
            guard let daemon, let connection = daemon.connection else { throw DaemonError.notConnected }
            let cwd = daemon.defaultCwd
            return try await connection.createTerminal(in: key, cwd: cwd).surface
        }, close: { [weak daemon] key in
            guard let daemon, let connection = daemon.connection else { throw DaemonError.notConnected }
            // No tab is left, so no terminal to end here.
            try await WorkspaceClose.close(key, terminals: [], on: connection)
        }, cause: { [weak daemon] key in
            // When the registry cannot be read, keep the workspace: a
            // needless repair costs one terminal, a needless close loses
            // the user's workspace.
            guard let connection = daemon?.connection, let terminals = try? await connection.listTerminals() else { return .terminalLost }
            return EmptiedWorkspaceCause.from(terminals, workspace: key)
        }, canCreate: { [weak daemon] in
            guard let daemon, daemon.store.isLoaded else { return false }
            if case .connected = daemon.store.connectionState { return true }
            return false
        }, epoch: { [weak daemon] in daemon?.store.connectionEpoch ?? 0 },
        isLive: { [weak daemon] in daemon?.store.isLoaded ?? false }, on: daemon.mainWork)
    }
}
