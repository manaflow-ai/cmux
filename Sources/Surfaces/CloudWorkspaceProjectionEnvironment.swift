import Foundation

/// Native projection operations supplied by the app, or an isolated test host.
@MainActor
struct CloudWorkspaceProjectionEnvironment {
    var bindings: () -> [UUID: WorkspaceCloudVMBinding]
    var close: (SurfaceProjection) -> Void
    var applyLayout: (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void

    init(
        bindings: @escaping () -> [UUID: WorkspaceCloudVMBinding] = { [:] },
        close: @escaping (SurfaceProjection) -> Void = { _ in },
        applyLayout: @escaping (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void = { _, _, _ in }
    ) {
        self.bindings = bindings
        self.close = close
        self.applyLayout = applyLayout
    }

    init(workspaces: CloudWorkspaceRenameEnvironment) {
        bindings = {
            Dictionary(uniqueKeysWithValues: workspaces.workspaces().compactMap { workspace in
                workspace.cloudVMBinding.map { (workspace.id, $0) }
            })
        }
        close = { projection in
            SurfacePaneFactory.closeExited(panelID: projection.panelID, in: projection.workspaceID)
        }
        applyLayout = { id, layout, projections in
            workspaces.workspace(id)?.applyCloudWorkspaceLayout(layout, projections: projections)
        }
    }
}
