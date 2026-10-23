public import CmuxNextDaemon

/// The daemon side of New Column (`new-pane-right`): a new terminal column right of the pane's.
/// On a daemon that takes client keys (`split-client-keys-v1`) the column shows in the key's turn
/// (``intendNow(on:provisional:)``), as Cmd-D's split does; otherwise it waits for the reply.
public struct NewColumnCommand: Sendable {
    public let pane: PaneID
    /// The new column's width, a viewport fraction.
    public let width: Double
    public let options: SpawnOptions

    public init(pane: PaneID, width: Double, options: SpawnOptions) {
        self.pane = pane
        self.width = width
        self.options = options
    }

    /// Whether `daemon` takes the optimistic column: it serves the client keys.
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        PaneSplitCommand.optimisticSplitEnabled && daemon.supports(DaemonCapabilities.splitClientKeys)
    }

    /// Sends the column and returns the new surface (the reply path).
    public func send(on daemon: DaemonService) async throws -> SurfaceCreated {
        let pane = pane, width = width, options = options
        return try await daemon.perform("new-pane-right") { connection in
            try await connection.newColumn(rightOf: pane, width: width, options: options)
        }
    }

    /// The optimistic column in two steps: `provisional` (made with
    /// ``ProvisionalPane/init(columnWidth:widths:treeWidth:)``) is in the store's visible records
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
        let pane = pane, width = width, sent = options
        let intent = Intent.splitPane(pane: pane, direction: .right, ratio: 0.5, provisional: provisional)
        let send = daemon.intendNow("new-pane-right", intent, transaction: transaction) { connection in
            try await connection.newColumn(rightOf: pane, width: width, options: sent)
        }
        return {
            guard let created = await send() else { throw PaneSplitFailure() }
            daemon.store.creations.noteReply(transaction, surface: created.surface)
            guard !daemon.store.creations.wasCancelled(transaction) else { throw PaneSplitCancelled() }
            return created
        }
    }
}
