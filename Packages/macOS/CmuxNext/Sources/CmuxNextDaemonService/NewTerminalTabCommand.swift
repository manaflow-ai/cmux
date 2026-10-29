public import CmuxNextDaemon

/// The daemon side of New Terminal Tab (`newSurface`, Ctrl-`): `new-tab` in a pane.
///
/// With `terminal-placement-env-v1` the command is optimistic (ctrl-backtick-instant): the
/// store shows a provisional terminal tab in the pane in the caller's turn, under the terminal
/// host id the request then names, so the daemon's tab carrying that id takes the stand-in's
/// place in one apply (``ProvisionalTab/matched(_:in:)``), whether its `tab-added` or the reply
/// comes first. Nothing on the key path waits for the daemon (it took 114 ms p50 and 660 ms p95
/// on a loaded Mac, plans/cmux-next/instant-new-surfaces.md).
public struct NewTerminalTabCommand: Sendable {
    /// The pane the tab goes in.
    public let pane: PaneID
    /// How to start its terminal; `terminalID` is set by ``intendNow(on:cwd:)``.
    public let options: SpawnOptions

    /// - Parameters:
    ///   - pane: the pane the new tab goes in.
    ///   - options: its spawn options (cwd, size, workspace, keep).
    public init(pane: PaneID, options: SpawnOptions) {
        self.pane = pane
        self.options = options
    }

    /// Whether `daemon` takes the optimistic create: it accepts a caller-chosen terminal id
    /// (`terminal-placement-env-v1`), which is what names the daemon's tab as this one.
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapability.terminalPlacementEnv.rawValue)
    }

    /// The provisional tab, and the work that sends `new-tab`.
    public struct Pending {
        /// The provisional tab's id (`TabModel.id`), shown in the pane when ``NewTerminalTabCommand/intendNow(on:cwd:)`` returns.
        public let tab: String
        /// Its surface.
        public let surface: SurfaceID
        /// Sends the request; returns the daemon's tab. Throws ``NewTerminalTabFailure`` when the
        /// daemon refused it (the stand-in is gone then) and ``NewTerminalTabCancelled`` when the
        /// person closed the stand-in first.
        public let send: @MainActor () async throws -> SurfaceCreated
    }

    /// Shows the provisional tab now (the store's intent log), before any await; the returned
    /// work sends the request.
    /// - Parameters:
    ///   - daemon: the pane's daemon.
    ///   - cwd: the start directory when it is only known later (an agent tab's working
    ///     directory, read while the stand-in shows); nil, or a nil result, keeps `options.cwd`.
    @MainActor
    public func intendNow(on daemon: DaemonService, cwd: Task<String?, Never>? = nil) -> Pending {
        let provisional = ProvisionalTab()
        let terminal = TerminalID.generate()
        var options = options
        options.terminalID = terminal
        let transaction = ClientTransactionID.generate()
        let pane = pane, sent = options
        let intent = Intent.createTab(pane: pane, provisional: provisional.terminal(terminal, cwd: options.cwd))
        let send = daemon.intendNow("new-tab", intent, transaction: transaction) { connection in
            var sent = sent
            if let cwd, let start = await cwd.value { sent.cwd = start }
            return try await connection.newTab(in: pane, options: sent)
        }
        return Pending(tab: provisional.id, surface: provisional.surface) {
            guard let created = await send() else { throw NewTerminalTabFailure() }
            ProvisionalTab.created(transaction, surface: created.surface, in: daemon.store)
            guard !daemon.store.creations.wasCancelled(transaction) else { throw NewTerminalTabCancelled() }
            return created
        }
    }
}

/// An optimistic new terminal tab the person closed before the daemon made it (CancelledCreation).
public struct NewTerminalTabCancelled: Error, CustomStringConvertible {
    public var description: String { "the tab closed before the daemon made it" }
}

/// An optimistic new terminal tab the daemon refused (the intent log removed the stand-in).
public struct NewTerminalTabFailure: Error, CustomStringConvertible {
    public var description: String { "the daemon refused the new tab" }
}
