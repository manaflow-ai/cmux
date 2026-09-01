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
    /// Mac or on a machine, a machine's screen, a browser, or a whole workspace's
    /// collection — exactly where a Vault session or a file dropped at the same
    /// spot would land. One path for every row kind: `SurfaceCatalog.projectGroup`
    /// with the real drop destination; the first resource takes the drop spot and
    /// the rest join it as tabs; the provider decides whether a resource means a
    /// new pane (cloud) or moving the one pane a local terminal has. A drop never
    /// reuses an existing pane elsewhere. The drop is accepted as soon as the
    /// request is dispatched; failures are logged here.
    @discardableResult
    @MainActor
    func handleSurfaceResourceDrop(
        group: SurfaceResourceGroup,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        catalog: SurfaceCatalog? = nil
    ) -> Bool {
        guard !group.isEmpty else { return false }
        let catalog = catalog ?? SurfaceCatalog.shared
        let target = SurfaceDestination.dropDestination(workspaceID: self.id, destination: destination)
#if DEBUG
        cmuxDebugLog("surfaces.drop workspace=\(self.id.uuidString.prefix(5)) group=\(group.title) count=\(group.resources.count) target=\(target)")
#endif
        Task { @MainActor in
            do {
                _ = try await catalog.projectGroup(group.resources, into: target, focus: true)
            } catch {
#if DEBUG
                cmuxDebugLog("surfaces.drop.failed group=\(group.title) error=\(error)")
#endif
            }
        }
        return true
    }
}
