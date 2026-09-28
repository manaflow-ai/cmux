import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeOutlineView {
    /// A terminal rename needs a stable daemon tab placement. A terminal row
    /// with only a legacy workspace hint is not enough, because the same
    /// terminal can have zero or many tab placements.
    static func canRenameTerminal(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> Bool {
        remoteView != nil || resource.remoteViews?.isEmpty == false
    }

    /// A rename writes a name onto a daemon tab, so a row with no tab has
    /// nothing to write to and must not offer the verb.
    ///
    /// Unlike a terminal, a display or a browser row is built from one
    /// placement, so there is no pool row and no all-views fallback: either
    /// this row has its tab or it is not renameable.
    ///
    /// A port row is not offered the verb even though its placement can carry
    /// a tab. The row renders the forwarded link and falls back to the port
    /// number, never to a name, so a rename would write something no row
    /// shows. Naming ports is its own change, in the row first.
    static func canRenameRemoteView(remoteView: SurfaceRemoteView?) -> Bool {
        remoteView != nil
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// The representable and native tests enter through the same update boundary.
    func update(inputs: CloudTreeBuildInputs, now: Date = .now) {
        guard let nodes = nodeCache.nodes(ifChanged: inputs, now: now) else { return }
        apply(nodes: nodes)
    }
}
