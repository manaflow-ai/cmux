public import CmuxNextDaemon

/// The daemon side of New Column (`new-pane-right`): a new terminal column right of the pane's,
/// or left of it for New Column Left (`side: "left"`, `column-left-v1`).
/// On a daemon that takes client keys (`split-client-keys-v1`) the column shows in the key's turn
/// (``intendNow(on:provisional:)``), as Cmd-D's split does; otherwise it waits for the reply.
public struct NewColumnCommand: Sendable {
    public let pane: PaneID
    /// The new column's width, a viewport fraction.
    public let width: Double
    /// Opens the column before the pane's column (New Column Left).
    public let left: Bool
    public let options: SpawnOptions

    public init(pane: PaneID, width: Double, left: Bool = false, options: SpawnOptions) {
        self.pane = pane
        self.width = width
        self.left = left
        self.options = options
    }

    /// Whether `daemon` can run this command: New Column Left needs `column-left-v1` (an older
    /// daemon would ignore `side` and open the column on the right).
    @MainActor public func isSupported(on daemon: DaemonService) -> Bool {
        !left || daemon.supports(DaemonCapability.columnLeft.rawValue)
    }

    /// Whether `daemon` takes the optimistic column: it serves the client keys.
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        PaneSplitCommand.optimisticSplitEnabled && daemon.supports(DaemonCapability.splitClientKeys.rawValue)
    }

    /// Sends the column and returns the new surface (the reply path).
    public func send(on daemon: DaemonService) async throws -> SurfaceCreated {
        let pane = pane, width = width, left = left, options = options
        return try await daemon.perform("new-pane-right") { connection in
            try await connection.newColumn(beside: pane, left: left, width: width, options: options)
        }
    }

    /// The optimistic column in two steps: `provisional` (made with
    /// ``ProvisionalPane/init(columnWidth:left:)``) is in the store's visible records
    /// when this returns, in the caller's turn; the returned work sends `new-pane-right` under its
    /// client-minted ids, so the daemon's pane replaces it under the same public id. A refusal
    /// removes it exactly; a close of the provisional pane first cancels it (``PaneSplitCancelled``).
    @MainActor
    public func intendNow(on daemon: DaemonService, provisional: ProvisionalPane) -> @MainActor () async throws -> SurfaceCreated {
        let transaction = ClientTransactionID.generate()
        var options = options
        options.paneID = provisional.paneID
        options.tabID = provisional.tabID
        options.terminalID = TerminalID(rawValue: provisional.terminalID)
        let pane = pane, width = width, left = left, sent = options
        // The stand-in's terminal opens in the folder this create sends: its tab shows it from the key's frame.
        let intent = Intent.splitPane(pane: pane, direction: .right, ratio: 0.5, provisional: provisional.opening(in: options.cwd))
        // The target at send time: a stand-in (a create pressed on a create in flight) has become the
        // daemon's pane by then (``DaemonStore/daemonHandle(showing:)``; creates of one workspace go
        // out in order, each once the store holds the one before).
        let target: @MainActor @Sendable () async throws -> PaneID = { try await daemon.store.daemonTarget(pane) }
        let send = daemon.intendNowReporting("new-pane-right", intent, transaction: transaction) { connection in
            try await connection.newColumn(beside: try await target(), left: left, width: width, options: sent)
        }
        return {
            // A failure is the real one (``NewTerminalTabCommand``, FC-1), never a fixed text that hides it.
            let created = try await send().get()
            daemon.store.creations.noteReply(transaction, surface: created.surface)
            guard !daemon.store.creations.wasCancelled(transaction) else { throw PaneSplitCancelled() }
            await daemon.store.applied(transaction, connection: daemon.connection)
            return created
        }
    }
}

