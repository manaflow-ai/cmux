import CmuxNextDaemon

/// New Floating Pane as one unit: a split on the right of a tiled pane of the screen, then `float-pane` on the pane
/// that the split made. The 2 requests are closures, so a test runs the act with stand-ins and no daemon.
struct NewFloatingPane {
    /// The store that holds the screens.
    let store: DaemonStore
    /// `split` on the right of the pane it gets; it returns the daemon's reply.
    let split: @MainActor (PaneID) async throws -> SurfaceCreated
    /// `float-pane` with `mode: on` for the pane it gets.
    let float: @MainActor (PaneID) async throws -> Void

    /// The pane that the split goes to: `pane`, or the last tiled pane of `screen` when `pane` floats.
    static func anchor(for pane: PaneID, on screen: ScreenModel) -> PaneID? {
        let floating = Set(screen.floating.map(\.pane))
        guard floating.contains(pane) else { return pane }
        return screen.panes.last { !floating.contains($0.handle) }?.handle ?? pane
    }

    /// Runs the act for the focused pane `pane`: the split, then the float of the pane that the reply names.
    func run(beside pane: PaneID) async throws {
        guard let screen = store.screen(containing: pane), let anchor = Self.anchor(for: pane, on: screen) else { return }
        let created = try await split(anchor)
        if let new = created.pane { try await float(new) }
    }

    /// Starts the act on `daemon` for the focused pane `pane`, with the daemon's 2 requests. A daemon without
    /// floating panes gets no request.
    static func start(on daemon: DaemonService, beside pane: PaneID) {
        guard daemon.floatsPanes, daemon.store.screen(containing: pane) != nil else { return }
        let label = "new-floating-pane"
        let options = SpawnOptions(workspace: daemon.store.workspace(containing: pane)?.key)
        // The ticket opens now, as `send` opens it: a caller that waits for the action's scope waits for the 2 requests.
        let ticket = daemon.openTicket(label)
        Task {
            do {
                guard let connection = daemon.connection else { throw DaemonError.notConnected }
                let act = NewFloatingPane(
                    store: daemon.store,
                    split: { try await connection.split($0, direction: .right, options: options) },
                    float: { _ = try await connection.floatPane($0, mode: .on) }
                )
                try await act.run(beside: pane)
                await daemon.closeTicket(ticket, label: label, error: nil, replying: connection)
            } catch {
                daemon.logCommandFailure(label, error: error)
                await daemon.closeTicket(ticket, label: label, error: error)
            }
        }
    }
}
