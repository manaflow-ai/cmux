import Bonsplit
import Foundation

extension SurfaceDestination {
    /// The catalog destination for a Bonsplit drop into `workspaceID`. Mirrors how
    /// `Workspace.handleSessionDrop` reads the same destination: a horizontal split
    /// is left/right and a vertical one up/down, with `insertFirst` meaning the new
    /// pane goes on the first (left/top) side; an insert becomes a tab in the pane at
    /// the requested index.
    static func dropDestination(
        workspaceID: UUID,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> SurfaceDestination {
        switch destination {
        case .insert(let paneID, let index):
            return .tab(workspaceID: workspaceID, paneID: paneID.id.uuidString, index: index)
        case .split(let paneID, let orientation, let insertFirst):
            let direction: SurfaceSplitDirection
            switch orientation {
            case .horizontal: direction = insertFirst ? .left : .right
            case .vertical: direction = insertFirst ? .up : .down
            }
            return .split(workspaceID: workspaceID, paneID: paneID.id.uuidString, direction: direction)
        }
    }
}

extension Workspace {
    /// Projects a Cloud tree row dropped into this workspace — a terminal on this
    /// Mac or on a machine, a machine's screen, a browser — exactly where a Vault
    /// session or a file dropped at the same spot would land. One path for every
    /// row kind: `SurfaceCatalog.project` with the real drop destination; the
    /// provider decides whether that means a new pane (cloud) or moving the one
    /// pane a local terminal has. A drop never reuses an existing pane elsewhere.
    /// The drop is accepted as soon as the request is dispatched; failures are
    /// logged by the catalog's caller.
    @discardableResult
    @MainActor
    func handleSurfaceResourceDrop(
        id: SurfaceResourceID,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        catalog: SurfaceCatalog? = nil
    ) -> Bool {
        let catalog = catalog ?? SurfaceCatalog.shared
        let target = SurfaceDestination.dropDestination(workspaceID: self.id, destination: destination)
#if DEBUG
        cmuxDebugLog("surfaces.drop workspace=\(self.id.uuidString.prefix(5)) resource=\(id) target=\(target)")
#endif
        Task { @MainActor in
            do {
                _ = try await catalog.project(id, into: target, focus: true, reuseExisting: false)
            } catch {
#if DEBUG
                cmuxDebugLog("surfaces.drop.failed resource=\(id) error=\(error)")
#endif
            }
        }
        return true
    }
}
