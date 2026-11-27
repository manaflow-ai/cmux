import CmuxSurfaceCatalogModel
import Foundation

/// Native projection operations supplied by the app, or an isolated test host.
@MainActor
struct CloudWorkspaceProjectionEnvironment {
    var bindings: () -> [UUID: WorkspaceCloudVMBinding]
    var close: (SurfaceProjection) -> Void
    var applyLayout: (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void
    var pendingCloudBrowserPanelIDs: (UUID) -> Set<UUID>

    init(
        bindings: @escaping () -> [UUID: WorkspaceCloudVMBinding] = { [:] },
        close: @escaping (SurfaceProjection) -> Void = { _ in },
        applyLayout: @escaping (UUID, SurfaceProjectionLayout, [SurfaceProjection]) -> Void = { _, _, _ in },
        pendingCloudBrowserPanelIDs: @escaping (UUID) -> Set<UUID> = { _ in [] }
    ) {
        self.bindings = bindings
        self.close = close
        self.applyLayout = applyLayout
        self.pendingCloudBrowserPanelIDs = pendingCloudBrowserPanelIDs
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
        pendingCloudBrowserPanelIDs = { id in
            workspaces.workspace(id)?.pendingCloudBrowserPanelIDs ?? []
        }
    }
}
