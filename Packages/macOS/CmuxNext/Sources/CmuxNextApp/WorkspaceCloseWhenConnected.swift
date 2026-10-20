import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar

/// Close Workspace for a workspace whose machine is not connected (a paused Cloud VM).
/// The row leaves the sidebar at the press, as every close does (`InstantClose`), and the
/// close goes to the machine's daemon when it connects again. Before, the request failed
/// with "not connected", the row came back and the close button looked broken.
@MainActor
enum WorkspaceCloseWhenConnected {
    static func close(_ workspace: WorkspaceModel, key: WorkspaceKey, on daemon: DaemonService, services: AppServices) {
        let id = workspace.id, owner = services.windows.registry.value.owner(of: id)
        // The last row of its room is never hidden (a window closes with its last workspace): say why nothing happens.
        guard InstantClose.begin(id, in: owner, windows: services.windows) else {
            return services.registry.refuse(RemoteStrings.closeMachineNotConnected(services.machines.machineName(daemon.machineID) ?? daemon.machineID))
        }
        let terminals = WorkspaceClose.closing(workspace, on: daemon)
        // task-owner: the person's close, kept until the machine connects; it ends with the app (the row then lists again).
        Task { @MainActor in
            for await ready in ObservationStream({ daemon.connection != nil }) where ready { break }
            let failure = await daemon.failure("close-workspace") { connection in
                try await WorkspaceClose.close(key, terminals: terminals, on: connection)
            }
            if failure == nil, let connection = daemon.connection { await daemon.store.applied(through: await connection.eventSequence()) }
            ClosingWorkspaces.shared.end(id, refused: failure != nil, in: owner.flatMap { services.windows.controller(for: $0)?.window })
        }
    }
}
