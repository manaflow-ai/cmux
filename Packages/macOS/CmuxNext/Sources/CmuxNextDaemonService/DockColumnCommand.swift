public import CmuxNextDaemon

/// The daemon side of docking a tab into a new column (`move-tab-to-column {dock}`). A lone tab
/// docked on the left with `respawn` (a lone chat docked by a new tab from its pane) shows in the
/// input's turn on a daemon that takes the column's pane id (`tab-column-client-pane-v1`): the
/// tab moves into a stand-in dock pane and its pane shows its fresh tab's stand-in
/// (``ProvisionalDock``), as New Column shows its column (``NewColumnCommand``). Otherwise, a
/// fresh browser tab included (its stand-in's page would not carry over to the daemon's tab), it
/// waits for the reply.
public struct DockColumnCommand: Sendable {
    public let move: MoveTabToColumnRequest
    public let respawn: SplitRespawn?

    public init(_ move: MoveTabToColumnRequest, respawn: SplitRespawn?) {
        self.move = move
        self.respawn = respawn
    }

    /// Shows the dock now when `daemon` can take it first, and returns the send: true when the
    /// daemon moved the tab. A refusal takes the stand-ins out exactly.
    @MainActor public func start(on daemon: DaemonService) -> @MainActor () async -> Bool {
        let move = move
        guard let respawn else {
            return {
                await daemon.request("move-tab-to-column") { connection -> Void in
                    _ = try await connection.moveTabToColumn(move.surface, target: move.target, width: move.width, dock: move.dock,
                                                             transaction: move.transaction)
                } != nil
            }
        }
        guard case .pane(let source) = move.target, case .terminal(var options) = respawn, let dock = move.dock,
              dock.edge == .left, let width = move.width, let transaction = move.transaction,
              daemon.supports(DaemonCapability.tabColumnClientPane.rawValue) else {
            return {
                await daemon.request("move-tab-to-column") { connection -> Void in
                    try await MoveTabToColumnRespawnRequest(move, respawn: respawn).send(on: connection)
                } != nil
            }
        }
        let provisional = ProvisionalPane(columnWidth: width, left: true)
        // The host id is minted here, so the stand-in and the daemon's tab show the same terminal.
        let terminal = options.terminalID ?? TerminalID.generate()
        options.terminalID = terminal
        let standIn = ProvisionalTab().terminal(terminal, cwd: options.cwd)
        let request = MoveTabToColumnRespawnRequest(move, respawn: .terminal(options), paneID: provisional.paneID)
        let intent = Intent.dockTab(surface: move.surface, pane: source, provisional: provisional, dock: dock, standIn: standIn)
        let send = daemon.intendNowReporting("move-tab-to-column", intent, transaction: transaction) { connection in
            try await request.send(on: connection)
        }
        return { (try? await send().get()) != nil }
    }

}
