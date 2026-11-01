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

    /// Whether `daemon` takes the optimistic row: it serves client keys on `new-row`.
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        PaneSplitCommand.optimisticSplitEnabled && daemon.supports(DaemonCapability.rowClientKeys.rawValue)
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
        // The target at send time (see ``NewColumnCommand``): a stand-in has become the daemon's pane.
        let target: @MainActor @Sendable () async throws -> PaneID = { try await daemon.store.daemonTarget(pane) }
        let send = daemon.intendNowReporting("new-row", intent, transaction: transaction) { connection in
            try await RowCommands(connection).newRow(below: try await target(), height: height, options: sent)
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
