import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// A machine that is gone (deleted, or access ended) takes its URL-backed
    /// panes with it: a display or browser pane holds a tokened gateway URL
    /// that decays into the hosting provider's raw error page once the
    /// workload is dead. Terminal panes stay — their attach process exits and
    /// the scrollback is still the user's to read.
    ///
    /// A delete closes them when it is confirmed, before the provider answers;
    /// the machine stays registered, so a failed delete can project them again.
    func closeURLBackedPanes(on machine: SurfaceMachineID) {
        let urlBacked = projections.filter {
            $0.resource.machine == machine
                && ($0.resource.kind == .display || $0.resource.kind == .browser)
        }
        let provider = provider(for: machine)
        for projection in urlBacked {
            if let provider {
                provider.discardMaterialization(projection)
            } else {
                // The registry removes its provider before calling us during a
                // fleet prune. There is still a real browser/display pane to
                // close, even though no provider remains to do it for us.
                SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
            }
        }
    }
}
