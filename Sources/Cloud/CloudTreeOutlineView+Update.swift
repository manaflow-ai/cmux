import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeOutlineView {
    /// A terminal rename needs a stable daemon tab placement. A terminal row
    /// with only a legacy workspace hint is not enough, because the same
    /// terminal can have zero or many tab placements.
    static func canRenameTerminal(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> Bool {
        remoteView != nil || resource.remoteViews?.isEmpty == false
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// The representable and native tests enter through the same update boundary.
    func update(inputs: CloudTreeBuildInputs, now: Date = .now) {
        guard let nodes = nodeCache.nodes(ifChanged: inputs, now: now) else { return }
        apply(nodes: CloudTreeCreateActionBuilder.add(to: nodes))
    }
}
