public import CmuxNextDaemon

/// The daemon side of New Row (`new-row`): a new terminal row below the pane's row. On a daemon
/// that takes client keys on `new-row` (`row-client-keys-v1`) the row shows in the key's turn
/// (``intendNow(on:provisional:)``); otherwise it waits for the reply.
public struct NewRowCommand: Sendable {
    public let pane: PaneID
    /// The new row's height, permille of the column's viewport height.
    public let height: Int
    public let options: SpawnOptions

    public init(pane: PaneID, height: Int, options: SpawnOptions) {
        self.pane = pane
        self.height = height
        self.options = options
    }

    /// Whether `daemon` takes the optimistic row: it serves client keys on `new-row`, and keeps
    /// them on the wire (`DaemonConnection.served` drops `pane_id` and `tab_id` without
    /// `split-client-keys-v1`, and `terminal_id` without `terminal-placement-env-v1`; the daemon's
    /// pane would then never be matched to the stand-in by its public id).
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        PaneSplitCommand.optimisticSplitEnabled && daemon.supports(DaemonCapabilities.rowClientKeys)
            && daemon.supports(DaemonCapabilities.splitClientKeys) && daemon.supports(DaemonCapabilities.terminalPlacementEnv)
    }

    /// Sends the row and returns the new surface (the reply path). A pane that is a pending
    /// create's stand-in is named by the daemon's pane for it (``DaemonStore/daemonTarget(for:)``).
    public func send(on daemon: DaemonService) async throws -> SurfaceCreated {
        let pane = try await daemon.store.daemonTarget(for: self.pane)
        let height = height, options = options
        return try await daemon.perform("new-row") { connection in
            try await RowCommands(connection).newRow(below: pane, height: height, options: options)
        }
    }

    /// The optimistic row in two steps: `provisional` (``ProvisionalPane/init(rowHeight:)``) is in
    /// the store's visible records when this returns; the returned work sends `new-row` under its
    /// client-minted ids. A refusal removes it exactly; a close first cancels it.
    @MainActor
    public func intendNow(on daemon: DaemonService, provisional: ProvisionalPane) -> @MainActor () async throws -> SurfaceCreated {
        let transaction = ClientTransactionID.generate()
        var options = options
        options.paneID = provisional.paneID
        options.tabID = provisional.tabID
        options.terminalID = TerminalID(rawValue: provisional.terminalID)
        let pane = pane, height = height, sent = options
        let intent = Intent.splitPane(pane: pane, direction: .down, ratio: 0.5, provisional: provisional)
        // The target at send time (``DaemonService/intendCreate``): never a stand-in's handle.
        let send = daemon.intendCreate("new-row", intent, transaction: transaction, target: pane) { connection, target in
            try await RowCommands(connection).newRow(below: target, height: height, options: sent)
        }
        return {
            guard let created = await send() else { throw PaneSplitFailure() }
            daemon.store.creations.noteReply(transaction, surface: created.surface)
            guard !daemon.store.creations.wasCancelled(transaction) else { throw PaneSplitCancelled() }
            return created
        }
    }
}
