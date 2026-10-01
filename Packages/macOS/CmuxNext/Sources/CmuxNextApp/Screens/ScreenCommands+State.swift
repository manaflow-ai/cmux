import CmuxNextDaemon

// A new screen with metadata on a daemon with state resources: the raw
// `new-screen` creates it, then the v2 state mutations give it its name,
// pin, color, icon, position and group (no single v2 operation creates a
// screen with metadata).
extension ScreenCommands {
    /// Applies `spec` to the screen that shows `surface` once the store has it.
    static func applySpec(_ spec: ScreenSpec, toScreenOf surface: SurfaceID, daemon: DaemonService,
                          connection: DaemonConnection) async throws {
        await daemon.store.applied(through: await connection.eventSequence())
        guard let pane = daemon.store.pane(containing: surface),
              let screen = daemon.store.workspaces.lazy.flatMap(\.screens).first(where: { $0.panes.contains { $0 === pane } }),
              let resource = screen.resourceID else { return }
        if let name = spec.name { try await connection.renameScreen(screen.handle, to: name) }
        if spec.pinned != nil || spec.color != nil || spec.icon != nil {
            try await connection.updateScreen(resource, pinned: spec.pinned, color: spec.color.map(FieldUpdate.set) ?? .unchanged,
                                              icon: spec.icon.map(FieldUpdate.set) ?? .unchanged)
        }
        if let index = spec.index { try await connection.moveScreen(resource, to: index) }
        if let group = spec.group, spec.pinned != true {
            try await connection.addScreens([resource], toScreenGroup: group.rawValue)
        }
    }
}
