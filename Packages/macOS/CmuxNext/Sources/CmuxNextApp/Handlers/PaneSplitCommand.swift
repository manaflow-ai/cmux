import CmuxNextDaemon

/// The daemon side of a pane split: `split` (right or down), then
/// `swap-pane` for a left or up split so the new pane lands on that side.
struct PaneSplitCommand: Sendable {
    let pane: PaneID
    let direction: SplitDirection
    let options: SpawnOptions
    /// Set for left and up splits: the original pane moves this way.
    let swapTowards: PaneDirection?

    /// Sends the split to `daemon` and returns the new surface.
    func send(on daemon: DaemonService) async throws -> SurfaceCreated {
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let created = try await connection.split(pane, direction: direction, options: options)
        if let swapTowards { try await connection.swapPane(pane, with: .direction(swapTowards)) }
        return created
    }
}
