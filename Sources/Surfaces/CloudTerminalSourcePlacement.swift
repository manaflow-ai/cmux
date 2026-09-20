import Foundation

/// Immutable Cloud identity captured at a terminal-create boundary.
///
/// A pending pane is a real terminal surface before its catalog projection exists.
/// Keeping its machine and remote workspace here lets the next split/new-terminal
/// action inherit the same placement even when focus has moved to that pane.
struct CloudTerminalSourcePlacement: Sendable {
    let machine: SurfaceMachineID
    let resource: SurfaceResource?
    let remoteWorkspaceID: String?
    let remoteTabID: String?
    let pendingCreation: CloudTerminalCreationReceipt?

    init(
        machine: SurfaceMachineID,
        resource: SurfaceResource? = nil,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil,
        pendingCreation: CloudTerminalCreationReceipt? = nil
    ) {
        self.machine = machine
        self.resource = resource
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteTabID = remoteTabID
        self.pendingCreation = pendingCreation
    }

    /// Resolve the pending source's own tab, never its ancestor's layout anchor.
    @MainActor
    func resolved() async throws -> CloudTerminalSourcePlacement {
        guard let pendingCreation else { return self }
        let created = try await pendingCreation.value()
        let view = try remoteView(of: created)
        guard view?.tabID.isEmpty == false else {
            // A dependent split must have an exact daemon tab anchor. The
            // workspace-only receipt is valid for its own pane but cannot safely
            // authorize a child layout mutation.
            throw CloudDiagnosticFailure.placement
        }
        return CloudTerminalSourcePlacement(
            machine: machine, resource: created,
            remoteWorkspaceID: remoteWorkspaceID ?? view?.workspace.id ?? created.remoteWorkspace?.id,
            remoteTabID: view?.tabID
        )
    }

    /// A receipt is accepted only for this machine and captured remote workspace.
    func validate(created: SurfaceResource) throws {
        guard created.machine == machine, created.kind == .terminal else {
            throw CloudDiagnosticFailure.placement
        }
        if let remoteWorkspaceID {
            if let views = created.remoteViews, !views.isEmpty {
                guard views.contains(where: { $0.workspace.id == remoteWorkspaceID }) else {
                    throw CloudDiagnosticFailure.placement
                }
            } else {
                guard created.remoteWorkspace?.id == remoteWorkspaceID else {
                    throw CloudDiagnosticFailure.placement
                }
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
