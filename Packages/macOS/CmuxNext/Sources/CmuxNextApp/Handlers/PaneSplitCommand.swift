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
}
