import Foundation

/// An immutable claim on one creating pane, retained only by its attachment task.
/// The factory checks the claim before any native pane mutation, so cancellation
/// cannot turn a delayed adoption into an ordinary new-terminal insertion.
struct CloudMachineLoadingReservation: Sendable {
    @TaskLocal static var current: CloudMachineLoadingReservation?

    let workspaceID: UUID
    let panelID: UUID
    let machineID: String

    @MainActor
    init?(_ resource: SurfaceResourceID, at destination: SurfaceDestination) {
        guard resource.kind == .terminal, let machineID = resource.machine.cloudMachineID,
              let workspace = Workspace.liveWorkspace(id: destination.workspaceID),
              let loading = workspace.cloudMachineLoadingPanel(at: destination, machineID: machineID) else { return nil }
        workspaceID = workspace.id
        panelID = loading.id
        self.machineID = machineID
    }

    @MainActor
    func loadingPanel(at destination: SurfaceDestination, machineID: String?) throws -> CloudVMLoadingPanel {
        guard destination.workspaceID == workspaceID, machineID == self.machineID,
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              !workspace.isRetiredFromOwningTabManager,
              workspace.cloudVMBinding?.vmID == self.machineID,
              let loading = workspace.panels[panelID] as? CloudVMLoadingPanel else { throw CancellationError() }
        return loading
    }
}
