import Foundation

/// Immutable Cloud identity captured at a terminal-create boundary.
///
/// A pending pane is a real terminal surface before its catalog projection exists.
/// Keeping its machine and remote workspace here lets the next split/new-terminal
/// action inherit the same placement even when focus has moved to that pane.
struct CloudTerminalSourcePlacement: Equatable, Sendable {
    let machine: SurfaceMachineID
    let resource: SurfaceResource?
    let remoteWorkspaceID: String?
    let remoteTabID: String?

    init(
        machine: SurfaceMachineID,
        resource: SurfaceResource? = nil,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.machine = machine
        self.resource = resource
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteTabID = remoteTabID
    }

    /// A receipt is accepted only for this machine and captured remote workspace.
    func validate(created: SurfaceResource) throws {
        guard created.machine == machine, created.kind == .terminal else {
            throw CloudDiagnosticFailure.placement
        }
        if let remoteWorkspaceID {
            guard created.remoteWorkspace?.id == remoteWorkspaceID
                    || created.remoteViews?.contains(where: { $0.workspace.id == remoteWorkspaceID }) == true else {
                throw CloudDiagnosticFailure.placement
            }
        }
    }

    func remoteView(of created: SurfaceResource) throws -> SurfaceRemoteView? {
        try validate(created: created)
        let views = (created.remoteViews ?? []).filter {
            remoteWorkspaceID == nil || $0.workspace.id == remoteWorkspaceID
        }
        guard views.count <= 1 else { throw CloudDiagnosticFailure.placement }
        return views.first
    }

}
