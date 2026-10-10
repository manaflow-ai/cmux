import CmuxNextDaemon

/// The daemon side of a pane split: `split` (right or down), then
/// `swap-pane` for a left or up split so the new pane lands on that side.
struct PaneSplitCommand: Sendable {
    let pane: PaneID
    let direction: SplitDirection
    let options: SpawnOptions
    /// Set for left and up splits: the original pane moves this way.
    let swapTowards: PaneDirection?

    /// Sends the split to `daemon` (the pane's own daemon, local or remote)
    /// and returns the new surface. It goes through the command funnel, so
    /// a running action's scope gets one ticket, the failure, and the write
    /// barrier that `action.run` waits for before it answers.
    func send(on daemon: DaemonService) async throws -> SurfaceCreated {
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
    func sendIntended(on daemon: DaemonService, provisional: ProvisionalPane) async throws -> SurfaceCreated {
        var options = options
        options.paneID = provisional.paneID
        options.tabID = provisional.tabID
        options.terminalID = TerminalID(rawValue: provisional.terminalID)
        let pane = pane, direction = direction, sent = options
        let intent = Intent.splitPane(pane: pane, direction: direction, ratio: 0.5, provisional: provisional)
        let created = await daemon.intend("split", intent, transaction: .generate()) { connection in
            try await connection.split(pane, direction: direction, options: sent)
        }
        guard let created else { throw PaneSplitFailure() }
        return created
    }

    /// The optimistic split is off (cx-wb5.72): keys typed right after Cmd+D lost the tail of the
    /// line in 1 of 8 proof runs. The landing that fixes the ordering sets this back to true.
    static let optimisticSplitEnabled = false

    /// Whether `daemon` takes the optimistic split for this command: the fast path is on, it serves
    /// the client keys, and the split does not swap (a left or up split moves the original pane
    /// afterwards).
    @MainActor func isOptimistic(on daemon: DaemonService) -> Bool {
        Self.optimisticSplitEnabled && swapTowards == nil
            && daemon.supports(DaemonCapabilities.shared.splitClientKeys)
    }
}

/// An optimistic split the daemon refused (the intent log logged the cause and removed the pane).
struct PaneSplitFailure: Error, CustomStringConvertible {
    var description: String { "the daemon refused the split" }
}
