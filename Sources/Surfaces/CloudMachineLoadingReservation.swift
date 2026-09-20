import Foundation

/// An immutable claim on one creating pane, retained only by its attachment task.
/// The factory checks the claim before any native pane mutation, so cancellation
/// cannot turn a delayed adoption into an ordinary new-terminal insertion.
struct CloudMachineLoadingReservation: Sendable {
    @TaskLocal static var current: CloudMachineLoadingReservation?

    let workspaceID: UUID
    let panelID: UUID
    let machineID: String
    var expectedRemoteWorkspaceID: String?
    var expectedRemoteTabID: String?

    @MainActor
    init?(_ resource: SurfaceResourceID, at destination: SurfaceDestination, remoteView: SurfaceRemoteView? = nil) {
        guard resource.kind == .terminal, let machineID = resource.machine.cloudMachineID,
              let workspace = Workspace.liveWorkspace(id: destination.workspaceID),
              let loading = workspace.cloudMachineLoadingPanel(at: destination, machineID: machineID) else { return nil }
        workspaceID = workspace.id
        panelID = loading.id
        self.machineID = machineID
        expectedRemoteWorkspaceID = remoteView?.workspace.id ?? resource.remoteWorkspace?.id
        expectedRemoteTabID = remoteView?.tabID
    }

    @MainActor
    init?(at destination: SurfaceDestination, machineID: String) {
        guard let workspace = Workspace.liveWorkspace(id: destination.workspaceID),
              let loading = workspace.cloudMachineLoadingPanel(at: destination, machineID: machineID) else { return nil }
        workspaceID = workspace.id
        panelID = loading.id
        self.machineID = machineID
        expectedRemoteWorkspaceID = nil
        expectedRemoteTabID = nil
    }

    @MainActor
    func loadingPanel(at destination: SurfaceDestination, machineID: String?) throws -> CloudVMLoadingPanel {
        guard destination.workspaceID == workspaceID, machineID == self.machineID,
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              !workspace.isRetiredFromOwningTabManager,
              workspace.cloudVMBinding?.vmID == self.machineID,
              expectedRemoteWorkspaceID == nil
                || workspace.cloudVMBinding?.remoteWorkspaceID == nil
                || workspace.cloudVMBinding?.remoteWorkspaceID == expectedRemoteWorkspaceID,
              let loading = workspace.panels[panelID] as? CloudVMLoadingPanel else { throw CancellationError() }
        return loading
    }

    func validate(materializedPlacement: SurfaceRemotePlacement?) throws {
        guard expectedRemoteWorkspaceID != nil || expectedRemoteTabID != nil else { return }
        guard let materializedPlacement,
              materializedPlacement.workspaceID == expectedRemoteWorkspaceID,
              expectedRemoteTabID == nil || materializedPlacement.tabID == expectedRemoteTabID else {
            throw CloudDiagnosticFailure.placement
        }
    }

    @MainActor
    var materializationDestination: SurfaceDestination? {
        guard let paneID = SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) else { return nil }
        return .tab(workspaceID: workspaceID, paneID: paneID, index: nil)
    }

    func withRemotePlacement(_ remoteView: SurfaceRemoteView?, remoteWorkspaceID: String?) -> Self {
        var copy = self
        copy.expectedRemoteWorkspaceID = remoteView?.workspace.id ?? remoteWorkspaceID
        copy.expectedRemoteTabID = remoteView?.tabID
        return copy
    }
}
