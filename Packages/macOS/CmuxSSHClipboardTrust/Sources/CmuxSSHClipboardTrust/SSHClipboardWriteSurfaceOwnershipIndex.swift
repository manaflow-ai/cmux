import CmuxSurfaceCatalogModel
import Foundation

/// Resolves panel ownership once for an SSH clipboard trust update.
///
/// A remote tmux window's inner panels are owned by a wrapper panel that can
/// disappear from `Workspace.panels` after the mirror materializes. Keeping
/// the catalog and pending-restore identities in one map lets propagation use
/// that wrapper identity without rescanning the catalog for every panel.
public struct SSHClipboardWriteSurfaceOwnershipIndex: Sendable {
    private let machineByPanelID: [UUID: SurfaceMachineID]

    /// Builds a snapshot of live and pending projection ownership.
    ///
    /// - Parameters:
    ///   - projections: Currently attached surface projections.
    ///   - pendingRestores: Pending restores, which take precedence for the same panel.
    public init(projections: [SurfaceProjection], pendingRestores: [SurfaceProjection]) {
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

    /// Looks up one panel without scanning projections.
    ///
    /// - Parameter panelID: A live panel or retired mirror wrapper identifier.
    /// - Returns: Its machine, or nil when no projection owns it.
    public func machine(for panelID: UUID) -> SurfaceMachineID? {
        machineByPanelID[panelID]
    }
}
