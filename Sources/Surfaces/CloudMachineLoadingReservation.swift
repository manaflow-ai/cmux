import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

/// An immutable claim on one creating pane, retained only by its attachment task.
/// The factory checks the claim before any native pane mutation, so cancellation
/// cannot turn a delayed adoption into an ordinary new-terminal insertion.
struct CloudMachineLoadingReservation: Sendable {
    /// The claim bound by the enclosing ``withCurrent(_:isolation:operation:)``.
    static var current: Self? { boundReservation?.value }

    // UUID fields give this value a run-time size; bind it by reference so
    // macOS 14's back-deployed TaskLocal fallback cannot abort.
    @TaskLocal private static var boundReservation: TaskLocalReference<CloudMachineLoadingReservation>?

    /// Runs `operation` with `reservation` as ``current``; `nil` clears an
    /// enclosing claim.
    static func withCurrent<T>(
        _ reservation: Self?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $boundReservation.withReferencedValue(reservation, isolation: isolation, operation: operation)
    }

    let workspaceID: UUID
    let panelID: UUID
    let machineID: String
    let expectedRemoteWorkspaceID: String?
    let expectedRemoteTabID: String?

    @MainActor
    init?(_ resource: SurfaceResourceID, at destination: SurfaceDestination, remoteView: SurfaceRemoteView? = nil) {
        guard resource.kind == .terminal, let machineID = resource.machine.cloudMachineID,
              let workspace = Workspace.liveWorkspace(id: destination.workspaceID),
              let loading = workspace.cloudMachineLoadingPanel(at: destination, machineID: machineID) else { return nil }
        workspaceID = workspace.id
        panelID = loading.id
        self.machineID = machineID
        expectedRemoteWorkspaceID = remoteView?.workspace.id
        expectedRemoteTabID = remoteView?.tabID
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

    @MainActor
    func validate(materializedPlacement: SurfaceRemotePlacement?) throws {
        guard let expectedRemoteTabID else { return }
        guard let materializedPlacement,
              materializedPlacement.workspaceID == expectedRemoteWorkspaceID,
              materializedPlacement.tabID == expectedRemoteTabID else { throw CloudDiagnosticFailure.placement }
    }
}


/// A browser pane opened at the New Display click, before the guest has
/// assigned the display. Display creation takes a round trip to the VM, so the
/// pane shows "Starting display…" immediately and the projection that follows
/// adopts it instead of opening a second pane.
struct CloudDisplayPaneReservation: Sendable {
    /// The reservation bound by the enclosing ``withCurrent(_:isolation:operation:)``.
    static var current: Self? { boundReservation?.value }

    // UUID fields give this value a run-time size; bind it by reference so
    // macOS 14's back-deployed TaskLocal fallback cannot abort.
    @TaskLocal private static var boundReservation: TaskLocalReference<CloudDisplayPaneReservation>?

    /// Runs `operation` with `reservation` as ``current``.
    static func withCurrent<T>(
        _ reservation: Self?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $boundReservation.withReferencedValue(reservation, isolation: isolation, operation: operation)
    }

    /// The display the guest created; only that resource may adopt the pane.
    let resource: SurfaceResourceID
    let workspaceID: UUID
    let panelID: UUID

    /// The reserved pane for the created display. Nil for any other resource,
    /// which opens its own pane. Throws when the person closed the reserved
    /// pane while the display started: the display stays in the pool rather
    /// than reappearing somewhere else.
    @MainActor
    func pane(for resource: SurfaceResource) throws -> (workspaceID: UUID, panelID: UUID)? {
        guard resource.id == self.resource else { return nil }
        guard SurfacePaneFactory.browserPanel(panelID: panelID, in: workspaceID) != nil else { throw CancellationError() }
        return (workspaceID, panelID)
    }
}
