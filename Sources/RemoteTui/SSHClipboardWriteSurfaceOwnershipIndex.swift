import CmuxSurfaceCatalogModel
import Foundation

/// Resolves panel ownership once for an SSH clipboard trust update.
///
/// A remote tmux window's inner panels are owned by a wrapper panel that can
/// disappear from `Workspace.panels` after the mirror materializes. Keeping
/// the catalog and pending-restore identities in one map lets propagation use
/// that wrapper identity without rescanning the catalog for every panel.
@MainActor
struct SSHClipboardWriteSurfaceOwnershipIndex {
    private let machineByPanelID: [UUID: SurfaceMachineID]

    init(catalog: SurfaceCatalog) {
        self.init(
            projections: Array(catalog.projections),
            pendingRestores: catalog.pendingRestoredProjections.projections
        )
    }

    init(projections: [SurfaceProjection], pendingRestores: [SurfaceProjection]) {
        var result: [UUID: SurfaceMachineID] = [:]
        result.reserveCapacity(projections.count + pendingRestores.count)
        for projection in projections {
            result[projection.panelID] = projection.resource.machine
        }
        for projection in pendingRestores {
            result[projection.panelID] = projection.resource.machine
        }
        machineByPanelID = result
    }

    func machine(for panelID: UUID) -> SurfaceMachineID? {
        machineByPanelID[panelID]
    }
}
