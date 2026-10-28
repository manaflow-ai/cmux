public import CmuxNextDaemon

/// The daemon side of a pane split: `split` (right or down), then
/// `swap-pane` for a left or up split so the new pane lands on that side.
public struct PaneSplitCommand: Sendable {
    public let pane: PaneID
    public let direction: SplitDirection
    public let options: SpawnOptions
    /// Set for left and up splits: the original pane moves this way.
    public let swapTowards: PaneDirection?

    public init(pane: PaneID, direction: SplitDirection, options: SpawnOptions, swapTowards: PaneDirection?) {
        self.pane = pane
        self.direction = direction
        self.options = options
        self.swapTowards = swapTowards
    }

    /// Sends the split to `daemon` (the pane's own daemon, local or remote)
    /// and returns the new surface. It goes through the command funnel, so
    /// a running action's scope gets one ticket, the failure, and the write
    /// barrier that `action.run` waits for before it answers.
    public func send(on daemon: DaemonService) async throws -> SurfaceCreated {
        let pane = pane, direction = direction, options = options, swapTowards = swapTowards
        return try await daemon.perform("split") { connection in
            let created = try await connection.split(pane, direction: direction, options: options)
            if let swapTowards { try await connection.swapPane(pane, with: .direction(swapTowards)) }
            return created
        }
    }

    /// The optimistic split (`split-client-keys-v1`, plans/cmux-next/remote-state-ownership.md
    /// S3): the store shows `provisional` beside the pane at once (its intent log), and the split
    /// goes out under the provisional pane's client-minted ids, so the daemon's pane replaces it
    /// under the same public id. A refusal removes it exactly.
    /// A close of the provisional pane first cancels the split (``DaemonService/cancelCreation(pane:)``):
    /// the reply's surface goes to that close at once, and this throws ``PaneSplitCancelled``, so
    /// nothing focuses or sizes the split the person closed.
    public func sendIntended(on daemon: DaemonService, provisional: ProvisionalPane) async throws -> SurfaceCreated {
        try await intendNow(on: daemon, provisional: provisional)()
    }

    /// ``sendIntended(on:provisional:)`` in two steps (Cmd-D, instant-new-surfaces): the
    /// provisional pane is in the store's visible records when this returns, in the caller's
    /// turn, so the window can lay it out in the key's frame; the returned work sends the split.
    @MainActor
    public func intendNow(on daemon: DaemonService, provisional: ProvisionalPane) -> @MainActor () async throws -> SurfaceCreated {
        let transaction = ClientTransactionID.generate()
        var options = options
        options.paneID = provisional.paneID
        options.tabID = provisional.tabID
        options.splitID = provisional.splitID
        options.terminalID = TerminalID(rawValue: provisional.terminalID)
        let pane = pane, direction = direction, sent = options
        let intent = Intent.splitPane(pane: pane, direction: direction, ratio: 0.5, provisional: provisional)
        let send = daemon.intendNow("split", intent, transaction: transaction) { connection in
            try await connection.split(pane, direction: direction, options: sent)
        }
        return {
            guard let created = await send() else { throw PaneSplitFailure() }
            daemon.store.creations.noteReply(transaction, surface: created.surface)
            guard !daemon.store.creations.wasCancelled(transaction) else { throw PaneSplitCancelled() }
            return created
        }
    }

    /// The optimistic split (cx-wb5.72). It was off while keys typed after Cmd+D could be lost;
    /// the key route of a pending creation (cx-wb5.76, `CreationInputCoordinator`) fixed the loss.
    public static let optimisticSplitEnabled = true

    /// Whether `daemon` takes the optimistic split for this command: the fast path is on, it serves
    /// the client keys, and the split does not swap (a left or up split moves the original pane
    /// afterwards).
    @MainActor public func isOptimistic(on daemon: DaemonService) -> Bool {
        Self.optimisticSplitEnabled && swapTowards == nil
            && daemon.supports(DaemonCapability.splitClientKeys.rawValue)
    }
}

/// An optimistic split whose pane the person closed before the daemon made it (CancelledCreation).
public struct PaneSplitCancelled: Error, CustomStringConvertible {
    public var description: String { "the pane closed before the daemon made it" }
}

/// An optimistic split the daemon refused (the intent log logged the cause and removed the pane).
public struct PaneSplitFailure: Error, CustomStringConvertible {
    public var description: String { "the daemon refused the split" }
}
